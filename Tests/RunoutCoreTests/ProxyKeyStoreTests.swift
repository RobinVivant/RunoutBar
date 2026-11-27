import Foundation
import Testing
@testable import RunoutCore

@Suite struct ProxyKeyStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runout-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savesTrimsOverwritesWith0600PermissionsAndClears() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested/proxy-key")

        #expect(ProxyKeyStore.load(from: file) == nil)

        try ProxyKeyStore.save("  tc-first-key\n ", to: file)
        #expect(ProxyKeyStore.load(from: file) == "tc-first-key")

        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)

        let dirAttrs = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)

        // Overwrite a looser file and verify atomic replacement restores 0600.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try ProxyKeyStore.save("tc-rotated-key", to: file)
        #expect(ProxyKeyStore.load(from: file) == "tc-rotated-key")
        let updatedPerms = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? Int
        #expect(updatedPerms == 0o600)

        // Empty save removes the file.
        try ProxyKeyStore.save("  \n ", to: file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(ProxyKeyStore.load(from: file) == nil)

        // Clearing an absent file is a no-op.
        try ProxyKeyStore.clear(at: file)
    }

    @Test func resolvesSavedFileBeforeConfigFallback() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("proxy-key")

        #expect(ProxyKeyStore.resolve(configKey: nil, from: file) == nil)
        #expect(ProxyKeyStore.resolve(configKey: "  \n ", from: file) == nil)
        #expect(ProxyKeyStore.resolve(configKey: " tc-from-config ", from: file) == "tc-from-config")

        try ProxyKeyStore.save("tc-from-file", to: file)
        #expect(ProxyKeyStore.resolve(configKey: "tc-from-config", from: file) == "tc-from-file")
    }
}
