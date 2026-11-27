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

    @Test func detectsLocalDashboards() {
        #expect(ProxyKeyStore.isLocalDashboard("http://127.0.0.1:3456/teamclaude/dashboard"))
        #expect(ProxyKeyStore.isLocalDashboard("http://localhost:3456/teamrouter/dashboard"))
        #expect(ProxyKeyStore.isLocalDashboard("https://[::1]:8443/teamclaude/dashboard"))
        #expect(!ProxyKeyStore.isLocalDashboard("https://proxy.example.com/teamclaude/dashboard"))
        #expect(!ProxyKeyStore.isLocalDashboard("not a url"))
    }

    @Test func readsOnlyProxyApiKeyFromLocalTeamClaudeOrTeamRouterConfig() throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let configDir = home.appendingPathComponent(".config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let localDashboard = "http://127.0.0.1:3456/teamclaude/dashboard"

        #expect(throws: ProxyKeyStore.ImportError.notLocalProxy) {
            try ProxyKeyStore.readLocalTeamClaudeProxyKey(
                dashboard: "https://proxy.example.com/teamclaude/dashboard", home: home.path, environment: [:])
        }
        #expect(throws: ProxyKeyStore.ImportError.configNotFound) {
            try ProxyKeyStore.readLocalTeamClaudeProxyKey(dashboard: localDashboard, home: home.path, environment: [:])
        }

        let tcFile = configDir.appendingPathComponent("teamclaude.json")
        try Data("""
        {
          "proxy": { "port": 3456, "apiKey": "  tc-legacy-key  ", "trustLoopback": false },
          "accounts": [{ "name": "a@example.com", "accessToken": "sk-ant-secret" }]
        }
        """.utf8).write(to: tcFile)
        #expect(try ProxyKeyStore.readLocalTeamClaudeProxyKey(
            dashboard: localDashboard, home: home.path, environment: [:]) == "tc-legacy-key")

        // Prefers teamrouter.json over teamclaude.json when present.
        let trFile = configDir.appendingPathComponent("teamrouter.json")
        try Data(#"{"proxy":{"apiKey":"tc-router-key"}}"#.utf8).write(to: trFile)
        #expect(try ProxyKeyStore.readLocalTeamClaudeProxyKey(
            dashboard: localDashboard, home: home.path, environment: [:]) == "tc-router-key")

        // Respects TEAMROUTER_CONFIG / XDG_CONFIG_HOME overrides and validates missing/corrupt files.
        let envFile = home.appendingPathComponent("custom.json")
        try Data(#"{"proxy":{"trustLoopback":false}}"#.utf8).write(to: envFile)
        #expect(throws: ProxyKeyStore.ImportError.missingApiKey) {
            try ProxyKeyStore.readLocalTeamClaudeProxyKey(
                dashboard: localDashboard, home: home.path, environment: ["TEAMROUTER_CONFIG": envFile.path])
        }

        try Data("not-json".utf8).write(to: envFile)
        #expect(throws: ProxyKeyStore.ImportError.unreadableConfig) {
            try ProxyKeyStore.readLocalTeamClaudeProxyKey(
                dashboard: localDashboard, home: home.path, environment: ["TEAMROUTER_CONFIG": envFile.path])
        }
    }
}
