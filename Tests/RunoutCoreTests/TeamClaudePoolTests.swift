import Foundation
import Network
import Testing
@testable import RunoutCore

private let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

/// The helper script, run by a real `node` against a stand-in TeamClaude package whose config loader
/// returns what the test wrote.
@Suite(.enabled(if: node != nil, "needs node")) struct TeamClaudePoolTests {
    /// A stand-in package folder, removed after the test. `config` is what its `loadConfig` returns:
    /// JSON, or nil for a config file that does not exist yet.
    final class Package {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-pool-\(UUID().uuidString)")
        var dir: String { url.appendingPathComponent("node_modules/@karpeleslab/teamclaude").path }

        init(config: String?, loader: String = "loadConfig") throws {
            let source = URL(fileURLWithPath: dir).appendingPathComponent("src")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("export async function \(loader)() { return \(config ?? "null"); }\n".utf8)
                .write(to: source.appendingPathComponent("config.js"))
            try Data("#!/usr/bin/env node\n".utf8).write(to: source.appendingPathComponent("index.js"))
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    func count(_ package: Package) async throws -> Int? {
        await TeamClaudePool.accountCount(node: try #require(node), packageDir: package.dir,
                                          environment: Shell.environment())
    }

    @Test func thePoolIsCountedThroughTeamClaudesOwnLoader() async throws {
        let pool = try Package(config: #"{"accounts":[{"name":"ada@example.com"},{"name":"openai","provider":"codex"}]}"#)
        #expect(try await count(pool) == 2)
    }

    @Test func noConfigYetIsAnEmptyPool() async throws {
        // Before the first login TeamClaude has no config file, and its loader returns nothing.
        #expect(try await count(try Package(config: nil)) == 0)
        #expect(try await count(try Package(config: "{}")) == 0)
    }

    @Test func aPoolThatCannotBeAskedIsUnknownNotEmpty() async throws {
        #expect(try await count(try Package(config: "{}", loader: "somethingElse")) == nil)
        let missing = try Package(config: "{}")
        try FileManager.default.removeItem(atPath: missing.dir + "/src/config.js")
        #expect(try await count(missing) == nil)
    }

    @Test func theScriptPrintsACountAndNothingOfTheConfig() async throws {
        let pool = try Package(config: #"{"proxy":{"apiKey":"made-up-key"},"accounts":[{"name":"ada@example.com","accessToken":"made-up-token"}]}"#)
        let result = try await Shell.run(try #require(node), TeamClaudePool.arguments(packageDir: pool.dir, action: "count"),
                                         environment: Shell.environment())
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"ok":true,"accounts":1}"#)
        #expect(!result.errorOutput.contains("made-up"))
    }

    @Test func aCLILeadsToItsPackage() throws {
        let pool = try Package(config: "{}")
        let bin = pool.url.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("teamclaude").path,
                                                   withDestinationPath: "../@karpeleslab/teamclaude/src/index.js")
        let cli = pool.url.appendingPathComponent("teamclaude").path
        try FileManager.default.createSymbolicLink(atPath: cli, withDestinationPath: bin.appendingPathComponent("teamclaude").path)
        let resolved = URL(fileURLWithPath: pool.dir).resolvingSymlinksInPath().path
        #expect(TeamClaudePool.packageDir(cli: cli, installDir: "/nowhere") == resolved)

        // A shim leads nowhere near the package: the copy in the npm prefix is used when there is one.
        let shim = pool.url.appendingPathComponent("shim").path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: shim))
        #expect(TeamClaudePool.packageDir(cli: shim, installDir: pool.url.path) == pool.dir)
        #expect(TeamClaudePool.packageDir(cli: shim, installDir: "/nowhere") == nil)
    }

    /// A one-request HTTP server: answers 200 and hands back what it was sent.
    func proxy() async throws -> (port: UInt16, request: Task<String, Never>) {
        let listener = try NWListener(using: .tcp, on: .any)
        let (requests, received) = AsyncStream<String>.makeStream()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                received.yield(String(decoding: data ?? Data(), as: UTF8.self))
                let body = #"{"ok":true,"added":0,"removed":0}"#
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n\(body)"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
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
        let request = Task {
            var iterator = requests.makeAsyncIterator()
            let text = await iterator.next() ?? ""
            listener.cancel()
            return text
        }
        return (port, request)
    }

    @Test func aReloadAsksTheRunningProxyWithItsKey() async throws {
        let (port, request) = try await proxy()
        let pool = try Package(config: #"{"proxy":{"port":\#(port),"apiKey":"made-up-key"},"accounts":[]}"#)
        #expect(await TeamClaudePool.reload(node: try #require(node), packageDir: pool.dir,
                                            environment: Shell.environment()))
        let sent = await request.value
        #expect(sent.hasPrefix("POST /teamclaude/reload HTTP/1.1"))
        #expect(sent.lowercased().contains("x-api-key: made-up-key"))
    }

    @Test func aReloadWithoutAProxyToAskIsNotConfirmed() async throws {
        // A config that names no port, as before the first server start.
        let pool = try Package(config: #"{"accounts":[]}"#)
        #expect(await !TeamClaudePool.reload(node: try #require(node), packageDir: pool.dir,
                                             environment: Shell.environment()))
    }
}
