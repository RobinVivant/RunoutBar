import Foundation

public enum SemVer {
    /// Only plain x.y.z is ever passed to npm, as TeamClaude's own updater does:
    /// the registry's "latest" is untrusted network input.
    public static func isRelease(_ version: String) -> Bool {
        version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    static func parts(_ version: String) -> [Int] {
        let core = version.split(separator: "+").first.map(String.init) ?? version
        let base = core.split(separator: "-").first.map(String.init) ?? core
        return base.split(separator: ".").map { Int($0) ?? 0 }
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = parts(a), pb = parts(b)
        for index in 0..<3 {
            let x = index < pa.count ? pa[index] : 0
            let y = index < pb.count ? pb[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Checks npm for TeamClaude / TeamRouter releases and installs one into the local npm
/// prefix the proxy runs from.
public enum TeamClaudeUpdates {
    public struct InstalledPackage: Sendable, Equatable {
        public var name: String
        public var version: String
        public var inInstallDir: Bool

        public init(name: String, version: String, inInstallDir: Bool) {
            self.name = name
            self.version = version
            self.inInstallDir = inInstallDir
        }
    }

    public static let teamRouterPackage = "teamrouter"
    public static let legacyPackage = "@karpeleslab/teamclaude"
    public static let allowedPackages = [teamRouterPackage, legacyPackage]
    public static let package = legacyPackage

    private static func readPackageJSON(at packageDir: URL) -> (name: String, version: String)? {
        let url = packageDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONValue.parse(data),
              let name = json["name"]?.string, allowedPackages.contains(name),
              let version = json["version"]?.string, !version.isEmpty else { return nil }
        return (name, version)
    }

    /// Detect the installed package name and version, checking `installDir` first and then following `cli`.
    /// When the legacy `@karpeleslab/teamclaude` shim sits beside or nests `teamrouter`, returns `teamrouter`.
    public static func installedPackage(cli: String? = nil, installDir: String,
                                        fileManager _: FileManager = .default) -> InstalledPackage? {
        let base = URL(fileURLWithPath: AppConfig.expand(installDir))
        for pkg in allowedPackages {
            let pkgDir = base.appendingPathComponent("node_modules/\(pkg)")
            if let info = readPackageJSON(at: pkgDir) {
                if info.name == legacyPackage,
                   let nested = readPackageJSON(at: pkgDir.appendingPathComponent("node_modules/\(teamRouterPackage)")) {
                    return InstalledPackage(name: nested.name, version: nested.version, inInstallDir: true)
                }
                return InstalledPackage(name: info.name, version: info.version, inInstallDir: true)
            }
        }
        guard let cli, !cli.isEmpty else { return nil }
        var dir = URL(fileURLWithPath: AppConfig.expand(cli)).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<3 {
            if let info = readPackageJSON(at: dir) {
                if info.name == legacyPackage {
                    if let nested = readPackageJSON(at: dir.appendingPathComponent("node_modules/\(teamRouterPackage)")) {
                        return InstalledPackage(name: nested.name, version: nested.version, inInstallDir: false)
                    }
                    let sibling = dir.deletingLastPathComponent().deletingLastPathComponent()
                        .appendingPathComponent(teamRouterPackage)
                    if let shimTarget = readPackageJSON(at: sibling) {
                        return InstalledPackage(name: shimTarget.name, version: shimTarget.version, inInstallDir: false)
                    }
                }
                return InstalledPackage(name: info.name, version: info.version, inInstallDir: false)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    public static func installedVersion(installDir: String) -> String? {
        installedPackage(installDir: installDir)?.version
    }

    /// The registry's current "latest" dist-tag.
    public static func latestVersion(package: String = legacyPackage,
                                     session: URLSession = .shared) async throws -> String {
        guard allowedPackages.contains(package) else { throw UpdateError.badPackage(package) }
        var request = URLRequest(url: URL(string: "https://registry.npmjs.org/\(package)")!)
        request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.registry }
        guard let latest = try JSONValue.parse(data)["dist-tags"]?["latest"]?.string else { throw UpdateError.registry }
        return latest
    }

    public enum UpdateError: LocalizedError {
        case registry, badVersion(String), badPackage(String), installFailed(String), restartFailed(String)

        public var errorDescription: String? {
            switch self {
            case .registry: return "Could not read the npm registry"
            case .badVersion(let v): return "Refusing to install \"\(v.prefix(40))\": not a release version"
            case .badPackage(let p): return "Refusing unsupported package \"\(p.prefix(40))\""
            case .installFailed(let output): return "npm install failed: \(output)"
            case .restartFailed(let output): return "Proxy restart failed: \(output)"
            }
        }
    }

    /// `npm install --prefix <dir> <package>@<version>`. A plain
    /// `teamclaude update` would run `npm install -g` and leave this copy as is.
    public static func installArguments(version: String, installDir: String,
                                        package: String = legacyPackage) throws -> [String] {
        guard allowedPackages.contains(package) else { throw UpdateError.badPackage(package) }
        guard SemVer.isRelease(version) else { throw UpdateError.badVersion(version) }
        return ["install", "--prefix", AppConfig.expand(installDir), "--no-audit", "--no-fund",
                "\(package)@\(version)"]
    }
}
