import Foundation
import Network

/// Whether TeamClaude is on this Mac, and the steps that put it there.
///
/// The install mirrors the layout the rest of the app expects: the package in its own npm prefix, a link to
/// its CLI, and the LaunchAgent that TeamClaude's own `service install` writes.
public enum TeamClaudeInstall {
    /// What the disk says about TeamClaude.
    public enum Finding: Sendable, Equatable {
        /// The CLI, at this path.
        case found(String)
        /// No CLI where this app looks. `traces` is true when a LaunchAgent or a TeamClaude config shows a
        /// copy somewhere else, which an install would collide with.
        case missing(traces: Bool)
    }

    public enum InstallError: LocalizedError, Equatable {
        /// Something that is not a link to TeamClaude sits where the CLI goes.
        case occupied(String)
        case npmFailed(String)
        case serviceFailed(String)
        case notStarted

        public var errorDescription: String? {
            switch self {
            case .occupied(let path): return "\(path) exists and is not TeamClaude. Move it, or set \"teamclaude\" in the config."
            case .npmFailed(let output): return "npm install failed: \(output)"
            case .serviceFailed(let output): return "The login service was not installed: \(output)"
            case .notStarted: return "TeamClaude is installed, but its proxy did not answer."
            }
        }
    }

    /// The oldest Node major version TeamClaude runs on (`engines.node` in its package).
    public static let minimumNode = 20

    static let cliName = "teamclaude"
    /// TeamClaude's config, under its current name and its earlier one.
    static let configNames = ["teamrouter.json", "teamclaude.json"]

    /// Where the CLI is looked for, in order: the configured path, then where npm and Homebrew put it.
    public static func candidates(configured: String, home: String) -> [String] {
        var paths: [String] = []
        for path in [AppConfig.expand(configured), "\(home)/.local/bin/\(cliName)", "/opt/homebrew/bin/\(cliName)",
                     "/usr/local/bin/\(cliName)"] where !path.isEmpty && !paths.contains(path) {
            paths.append(path)
        }
        return paths
    }

    public static func launchAgentURL(home: String, label: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The script a TeamClaude LaunchAgent runs: `node <script> server --headless`.
    public static func launchAgentEntry(_ plist: Data) -> String? {
        guard let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let arguments = root["ProgramArguments"] as? [String],
              let server = arguments.firstIndex(of: "server"), server > 0 else { return nil }
        return arguments[server - 1]
    }

    public static func find(config: AppConfig, home: String = NSHomeDirectory(),
                            fileManager: FileManager = .default) -> Finding {
        for path in candidates(configured: config.teamclaude, home: home) where fileManager.isExecutableFile(atPath: path) {
            return .found(path)
        }
        // A copy installed with another Node, such as one from nvm, is in none of the usual folders. Its
        // LaunchAgent still says where it is.
        let agent = launchAgentURL(home: home, label: config.proxyService)
        let plist = try? Data(contentsOf: agent)
        if let plist, let entry = launchAgentEntry(plist), fileManager.isExecutableFile(atPath: entry) {
            return .found(entry)
        }
        let configured = configNames.contains { fileManager.fileExists(atPath: "\(home)/.config/\($0)") }
        return .missing(traces: plist != nil || configured)
    }

    /// The major version in the output of `node --version`, such as 22 for "v22.11.0".
    public static func nodeMajor(_ output: String) -> Int? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("v"), let major = text.dropFirst().split(separator: ".").first else { return nil }
        return Int(major)
    }

    /// A tool such as npm: the configured path when it runs, else the first one on `path`.
    public static func locateTool(_ name: String, configured: String, path: String,
                                  fileManager: FileManager = .default) -> String? {
        let configured = AppConfig.expand(configured)
        if fileManager.isExecutableFile(atPath: configured) { return configured }
        return path.split(separator: ":").map { "\($0)/\(name)" }.first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// The CLI inside the npm prefix, which outlives a reinstall of the package.
    public static func packagedCLI(installDir: String) -> String {
        AppConfig.expand(installDir) + "/node_modules/.bin/\(cliName)"
    }

    /// Link `cli` to the package's CLI. A link that leads nowhere is replaced; anything else in the way stays.
    public static func link(cli: String, installDir: String, fileManager: FileManager = .default) throws {
        let (cli, target) = (AppConfig.expand(cli), packagedCLI(installDir: installDir))
        guard cli != target else { return }
        if let current = try? fileManager.destinationOfSymbolicLink(atPath: cli) {
            if current == target { return }
            // `fileExists` follows the link, so false means it leads nowhere.
            guard !fileManager.fileExists(atPath: cli) else { throw InstallError.occupied(cli) }
            try fileManager.removeItem(atPath: cli)
        } else if fileManager.fileExists(atPath: cli) {
            throw InstallError.occupied(cli)
        }
        try fileManager.createDirectory(atPath: (cli as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: cli, withDestinationPath: target)
    }

    /// Whether something listens on the proxy's port. A proxy this app cannot find on disk, such as one in
    /// a container, shows this way.
    public static func proxyAnswers(dashboard: String, timeout: TimeInterval = 2) async -> Bool {
        guard let url = URL(string: dashboard), let host = url.host, ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 80)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let answered: Bool? = try? await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(.success(true))
                // `waiting` is a refused connection that the system would retry.
                case .failed, .waiting, .cancelled: once.resume(.success(false))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(.success(false)) }
        }
        connection.cancel()
        return answered ?? false
    }

    /// TeamClaude's own command for its LaunchAgent: it writes the plist and loads it.
    public static let serviceArguments = ["service", "install"]
}
