import Darwin
import Foundation

/// Reads and writes the user's optional proxy API key (`~/.config/runout-bar/proxy-key`) with `0600`
/// permissions so rebuilding an ad-hoc signed app never triggers macOS login Keychain prompts.
public enum ProxyKeyStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/runout-bar/proxy-key")
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
