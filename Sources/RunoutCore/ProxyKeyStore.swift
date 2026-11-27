import Darwin
import Foundation

/// Reads and writes the user's optional proxy API key (`~/.config/runout-bar/proxy-key`) with `0600`
/// permissions so rebuilding an ad-hoc signed app never triggers macOS login Keychain prompts.
public enum ProxyKeyStore {
    public enum ImportError: LocalizedError, Equatable {
        case notLocalProxy
        case configNotFound
        case unreadableConfig
        case missingApiKey

        public var errorDescription: String? {
            switch self {
            case .notLocalProxy: return "Only local TeamClaude proxies can import a key from disk."
            case .configNotFound: return "No local TeamRouter or TeamClaude config file was found."
            case .unreadableConfig: return "Could not read the local TeamClaude config file."
            case .missingApiKey: return "No proxy.apiKey is set in the local TeamClaude config."
            }
        }
    }

    private struct ProxyConfigSlice: Decodable {
        struct Proxy: Decodable {
            var apiKey: String?
        }

        var proxy: Proxy?
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/runout-bar/proxy-key")
    }

    public static func isLocalDashboard(_ dashboard: String) -> Bool {
        guard let url = URL(string: dashboard),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// Reads only `proxy.apiKey` from the local TeamRouter/TeamClaude config on explicit user request
    /// after HTTP `401`. Never decodes `accounts` or OAuth credentials.
    public static func readLocalTeamClaudeProxyKey(
        dashboard: String,
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> String {
        guard isLocalDashboard(dashboard) else {
            throw ImportError.notLocalProxy
        }
        let candidates = TeamClaudeInstall.configFiles(home: home, environment: environment)
        guard let path = candidates.first(where: { fileManager.fileExists(atPath: $0) }) else {
            throw ImportError.configNotFound
        }
        guard let data = fileManager.contents(atPath: path),
              let decoded = try? JSONDecoder().decode(ProxyConfigSlice.self, from: data) else {
            throw ImportError.unreadableConfig
        }
        let key = decoded.proxy?.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            throw ImportError.missingApiKey
        }
        return key
    }

    public static func load(from url: URL = defaultURL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func save(_ key: String, to url: URL = defaultURL) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try clear(at: url)
            return
        }
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        let fd = Darwin.open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var closed = false
        var renamed = false
        defer {
            if !closed { _ = Darwin.close(fd) }
            if !renamed { _ = Darwin.unlink(tmp.path) }
        }
        guard Darwin.fchmod(fd, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let bytes = Array("\(trimmed)\n".utf8)
        try bytes.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if written == 0 {
                    throw POSIXError(.EIO)
                }
                offset += written
            }
        }
        guard Darwin.fsync(fd) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let closeResult = Darwin.close(fd)
        closed = true
        guard closeResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.rename(tmp.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        renamed = true
    }

    public static func clear(at url: URL = defaultURL) throws {
        if Darwin.unlink(url.path) != 0 {
            let err = errno
            if err != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
            }
        }
    }

    public static func resolve(configKey: String?, from url: URL = defaultURL) -> String? {
        if let saved = load(from: url) { return saved }
        let trimmed = configKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
