import Foundation
import Network
import Testing
@testable import RunoutCore

@Suite struct TeamClaudeInstallTests {
    /// A made-up home folder, removed after the test.
    final class Home {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-\(UUID().uuidString)")
        var path: String { url.path }

        init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: url) }

        @discardableResult func executable(_ relative: String) throws -> String {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return file.path
        }

        func file(_ relative: String, _ data: Data = Data()) throws {
            let file = url.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }

    func config(_ home: Home) -> AppConfig {
        var config = AppConfig()
        config.teamclaude = "\(home.path)/.local/bin/teamclaude"
        config.teamclaudeInstallDir = "\(home.path)/.local/share/teamclaude"
        return config
    }

    func launchAgent(entry: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": "com.karpeleslab.teamclaude",
            "ProgramArguments": ["/opt/homebrew/bin/node", entry, "server", "--headless"],
        ], format: .xml, options: 0)
    }

    @Test func theConfiguredPathComesFirstThenTheUsualFolders() {
        let paths = TeamClaudeInstall.candidates(configured: "/somewhere/teamclaude", home: "/Users/ada")
        #expect(paths == ["/somewhere/teamclaude", "/Users/ada/.local/bin/teamclaude", "/opt/homebrew/bin/teamclaude",
                          "/usr/local/bin/teamclaude"])
        // The default is one of the usual folders, and is not listed twice.
        #expect(TeamClaudeInstall.candidates(configured: "/Users/ada/.local/bin/teamclaude", home: "/Users/ada").count == 3)
    }

    @Test func aCLIAtTheConfiguredPathIsFound() throws {
        let home = try Home()
        let cli = try home.executable(".local/bin/teamclaude")
        #expect(TeamClaudeInstall.find(config: config(home), home: home.path) == .found(cli))
    }

    @Test func anEmptyHomeHasNoTeamClaudeAndNoTraces() throws {
        let home = try Home()
        #expect(TeamClaudeInstall.find(config: config(home), home: home.path) == .missing(traces: false))
    }

    @Test func aFileThatCannotRunIsNotACLI() throws {
        let home = try Home()
        try home.file(".local/bin/teamclaude")
        #expect(TeamClaudeInstall.find(config: config(home), home: home.path) == .missing(traces: false))
    }

    @Test func theLaunchAgentPointsAtACopyInstalledElsewhere() throws {
        let home = try Home()
        let entry = try home.executable(".nvm/versions/node/v22.1.0/lib/node_modules/@karpeleslab/teamclaude/src/index.js")
        try home.file("Library/LaunchAgents/com.karpeleslab.teamclaude.plist", try launchAgent(entry: entry))
        #expect(TeamClaudeInstall.find(config: config(home), home: home.path) == .found(entry))
    }

    @Test func aLaunchAgentOrAConfigWithoutACLIIsATrace() throws {
        let stale = try Home()
        try stale.file("Library/LaunchAgents/com.karpeleslab.teamclaude.plist",
                       try launchAgent(entry: "\(stale.path)/gone/index.js"))
        #expect(TeamClaudeInstall.find(config: config(stale), home: stale.path) == .missing(traces: true))

        for name in ["teamclaude.json", "teamrouter.json"] {
            let home = try Home()
            try home.file(".config/\(name)", Data("{}".utf8))
            #expect(TeamClaudeInstall.find(config: config(home), home: home.path) == .missing(traces: true))
        }
    }

    @Test func theLaunchAgentNamesItsScriptBeforeTheServerArgument() throws {
        #expect(TeamClaudeInstall.launchAgentEntry(try launchAgent(entry: "/a/src/index.js")) == "/a/src/index.js")
        #expect(TeamClaudeInstall.launchAgentEntry(Data("not a plist".utf8)) == nil)
        let other = try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": ["/bin/sleep", "5"]],
                                                       format: .xml, options: 0)
        #expect(TeamClaudeInstall.launchAgentEntry(other) == nil)
    }

    @Test func aProxyThatListensAnswersAndAClosedPortDoesNot() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream<Bool> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(true) }
                if case .failed = state { continuation.yield(false) }
            }
        }
        listener.start(queue: .global())
        var iterator = ready.makeAsyncIterator()
        #expect(await iterator.next() == true)
        let port = try #require(listener.port?.rawValue)
        #expect(await TeamClaudeInstall.proxyAnswers(dashboard: "http://127.0.0.1:\(port)/teamclaude/dashboard"))

        listener.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !TeamClaudeInstall.proxyAnswers(dashboard: "http://127.0.0.1:\(port)/teamclaude/dashboard"))
        // Only this Mac is asked: a dashboard on another host is not probed.
        #expect(await !TeamClaudeInstall.proxyAnswers(dashboard: "http://example.com/teamclaude/dashboard"))
    }

    @Test func theProxyCountsItsAccountsOfEveryProvider() throws {
        // A pool that only has Codex accounts is no empty pool.
        let status = Data(#"""
        {"server":{"version":"1.1.30"},"probe":{"accounts":[]},"accounts":[
          {"name":"openai","provider":"codex","type":"apikey"},
          {"name":"off@example.com","provider":"anthropic","type":"oauth","disabled":true}]}
        """#.utf8)
        let (accounts, proxy) = try TeamClaudeStatus.parse(status, config: AppConfig())
        #expect(accounts.isEmpty)
        #expect(proxy.up)
        #expect(proxy.accountCount == 1)
    }

    @Test func aConfigSomewhereElseIsATraceToo() throws {
        let home = try Home()
        try home.file("xdg/teamclaude.json", Data("{}".utf8))
        try home.file("elsewhere/pool.json", Data("{}".utf8))
        #expect(TeamClaudeInstall.find(config: config(home), home: home.path, environment: [:]) == .missing(traces: false))
        #expect(TeamClaudeInstall.find(config: config(home), home: home.path,
                                       environment: ["XDG_CONFIG_HOME": "\(home.path)/xdg"]) == .missing(traces: true))
        #expect(TeamClaudeInstall.find(config: config(home), home: home.path,
                                       environment: ["TEAMROUTER_CONFIG": "\(home.path)/elsewhere/pool.json"])
            == .missing(traces: true))
    }

    @Test func aCLIFromAnotherNodeManagerIsFound() throws {
        let nvm = try Home()
        try nvm.executable(".nvm/versions/node/v20.9.0/bin/teamclaude")
        let newest = try nvm.executable(".nvm/versions/node/v22.11.0/bin/teamclaude")
        #expect(TeamClaudeInstall.find(config: config(nvm), home: nvm.path, environment: [:]) == .found(newest))

        let volta = try Home()
        let shim = try volta.executable(".volta/bin/teamclaude")
        #expect(TeamClaudeInstall.find(config: config(volta), home: volta.path, environment: [:]) == .found(shim))
    }

    @Test func nodeIsTakenFromTheConfigTheCLIsFolderAndTheLaunchAgent() throws {
        let home = try Home()
        var config = config(home)
        config.node = try home.executable("tools/node")
        let cli = try home.executable(".nvm/versions/node/v22.11.0/bin/teamclaude")
        try home.executable(".nvm/versions/node/v22.11.0/bin/node")
        let agentNode = try home.executable("agent/bin/node")
        try home.file("Library/LaunchAgents/com.karpeleslab.teamclaude.plist",
                      try PropertyListSerialization.data(fromPropertyList: [
                          "ProgramArguments": [agentNode, "/a/src/index.js", "server", "--headless"],
                      ], format: .xml, options: 0))
        #expect(TeamClaudeInstall.nodeFolders(config: config, cli: cli, home: home.path)
            == ["\(home.path)/tools", "\(home.path)/.nvm/versions/node/v22.11.0/bin", "\(home.path)/agent/bin"])
        // A folder without a Node adds nothing.
        config.node = "\(home.path)/missing/node"
        #expect(TeamClaudeInstall.nodeFolders(config: config, cli: "\(home.path)/.local/bin/teamclaude", home: home.path)
            == ["\(home.path)/agent/bin"])
    }

    @Test func theChosenNodeComesFirstOnThePath() {
        let path = Shell.environment(first: ["/chosen/bin", "/usr/bin"])["PATH"] ?? ""
        let folders = path.split(separator: ":").map(String.init)
        #expect(folders.first == "/chosen/bin")
        #expect(folders.filter { $0 == "/usr/bin" }.count == 1)
        #expect(folders.contains("/opt/homebrew/bin"))
    }

    @Test func aDashboardOnAnotherMachineIsNotLocal() {
        #expect(TeamClaudeInstall.localEndpoint(dashboard: "http://127.0.0.1:3456/teamclaude/dashboard")?.port == 3456)
        #expect(TeamClaudeInstall.localEndpoint(dashboard: "http://proxy.example:3456/teamclaude/dashboard") == nil)
        #expect(TeamClaudeInstall.localEndpoint(dashboard: "not a url") == nil)
    }

    @Test func nodeVersionsAreReadFromNodeItself() {
        #expect(TeamClaudeInstall.nodeMajor("v22.11.0\n") == 22)
        #expect(TeamClaudeInstall.nodeMajor("v18.20.4") == 18)
        #expect(TeamClaudeInstall.nodeMajor("command not found") == nil)
        #expect(TeamClaudeInstall.minimumNode == 20)
    }

    @Test func aToolIsTakenFromTheConfigThenFromThePath() throws {
        let home = try Home()
        let configured = try home.executable("tools/npm")
        let onPath = try home.executable("bin/npm")
        let path = "\(home.path)/empty:\(home.path)/bin"
        #expect(TeamClaudeInstall.locateTool("npm", configured: configured, path: path) == configured)
        #expect(TeamClaudeInstall.locateTool("npm", configured: "\(home.path)/gone/npm", path: path) == onPath)
        #expect(TeamClaudeInstall.locateTool("npm", configured: "\(home.path)/gone/npm", path: "\(home.path)/empty") == nil)
    }

    @Test func theCLIIsLinkedToTheInstalledPackage() throws {
        let home = try Home()
        let installDir = "\(home.path)/.local/share/teamclaude"
        let target = try home.executable(".local/share/teamclaude/node_modules/.bin/teamclaude")
        let cli = "\(home.path)/.local/bin/teamclaude"

        try TeamClaudeInstall.link(cli: cli, installDir: installDir)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: cli) == target)
        #expect(FileManager.default.isExecutableFile(atPath: cli))

        // Linking again changes nothing, and a link left dangling by a removed copy is replaced.
        try TeamClaudeInstall.link(cli: cli, installDir: installDir)
        try FileManager.default.removeItem(atPath: cli)
        try FileManager.default.createSymbolicLink(atPath: cli, withDestinationPath: "\(home.path)/gone")
        try TeamClaudeInstall.link(cli: cli, installDir: installDir)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: cli) == target)
    }

    @Test func aFileInTheWayOfTheLinkIsLeftAlone() throws {
        let home = try Home()
        try home.executable(".local/share/teamclaude/node_modules/.bin/teamclaude")
        try home.file(".local/bin/teamclaude", Data("mine".utf8))
        let cli = "\(home.path)/.local/bin/teamclaude"
        #expect(throws: TeamClaudeInstall.InstallError.occupied(cli)) {
            try TeamClaudeInstall.link(cli: cli, installDir: "\(home.path)/.local/share/teamclaude")
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: cli)) == Data("mine".utf8))
    }
}
