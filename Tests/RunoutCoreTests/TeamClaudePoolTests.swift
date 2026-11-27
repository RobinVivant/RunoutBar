import Foundation
import Network
import Testing
@testable import RunoutCore

/// Tests package directory discovery (without importing `src/`) and HTTP `/reload` calls.
@Suite struct TeamClaudePoolTests {
    final class Package {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("runout-bar-pool-\(UUID().uuidString)")
        let dir: String

        init(packagePath: String = "@karpeleslab/teamclaude", name: String = "@karpeleslab/teamclaude") throws {
            let pkgURL = url.appendingPathComponent("node_modules/\(packagePath)")
            self.dir = pkgURL.path
            let source = pkgURL.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data(#"{"name": "\#(name)", "version": "1.1.31"}"#.utf8)
                .write(to: pkgURL.appendingPathComponent("package.json"))
            try Data("#!/usr/bin/env node\n".utf8).write(to: source.appendingPathComponent("index.js"))
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    struct HTTPRequest {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    final class StubServer: @unchecked Sendable {
        let listener: NWListener
        let port: UInt16
        private let requests: AsyncStream<HTTPRequest>

        init(statusCode: Int = 200, body: String = #"{"ok":true,"added":0,"removed":0}"#) async throws {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener
            let (stream, continuation) = AsyncStream<HTTPRequest>.makeStream()
            self.requests = stream

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                Self.readHTTPRequest(connection: connection, buffer: Data()) { req in
                    if let req { continuation.yield(req) }
                    let reason = statusCode == 200 ? "OK" : "Error"
                    let reply = "HTTP/1.1 \(statusCode) \(reason)\r\nContent-Type: application/json\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            let ready = AsyncStream<Bool> { stateCont in
                listener.stateUpdateHandler = { state in
                    if case .ready = state { stateCont.yield(true) }
                    if case .failed = state { stateCont.yield(false) }
                }
            }
            listener.start(queue: .global())
            var it = ready.makeAsyncIterator()
            #expect(await it.next() == true)
            self.port = try #require(listener.port?.rawValue)
        }

        func nextRequest() async -> HTTPRequest? {
            var it = requests.makeAsyncIterator()
            return await it.next()
        }

        func stop() { listener.cancel() }

        private static func readHTTPRequest(connection: NWConnection, buffer: Data,
                                            done: @escaping (HTTPRequest?) -> Void) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { chunk, _, isComplete, _ in
                var data = buffer
                if let chunk { data.append(chunk) }
                if let split = data.range(of: Data("\r\n\r\n".utf8)) {
                    let headerText = String(decoding: data[..<split.lowerBound], as: UTF8.self)
                    let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
                    let first = lines.first?.split(separator: " ") ?? []
                    let method = first.count > 0 ? String(first[0]) : ""
                    let path = first.count > 1 ? String(first[1]) : ""
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                            headers[key] = value
                        }
                    }
                    let expectedLength = headers["content-length"].flatMap(Int.init) ?? 0
                    let bodyData = Data(data[split.upperBound...])
                    if bodyData.count >= expectedLength || isComplete {
                        done(HTTPRequest(method: method, path: path, headers: headers,
                                         body: Data(bodyData.prefix(expectedLength))))
                        return
                    }
                }
                if isComplete {
                    done(nil)
                    return
                }
                readHTTPRequest(connection: connection, buffer: data, done: done)
            }
        }
    }

    @Test func aCLILeadsToItsPackage() throws {
        let pool = try Package()
        let bin = pool.url.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("teamclaude").path,
                                                   withDestinationPath: "../@karpeleslab/teamclaude/src/index.js")
        let cli = pool.url.appendingPathComponent("teamclaude").path
        try FileManager.default.createSymbolicLink(atPath: cli, withDestinationPath: bin.appendingPathComponent("teamclaude").path)
        let resolved = URL(fileURLWithPath: pool.dir).resolvingSymlinksInPath().path
        #expect(TeamClaudePool.packageDir(cli: cli, installDir: "/nowhere") == resolved)

        // Works for the renamed `teamrouter` package too, with no dependency on `src/config.js`.
        let router = try Package(packagePath: "teamrouter", name: "teamrouter")
        let rBin = router.url.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: rBin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: rBin.appendingPathComponent("teamrouter").path,
                                                   withDestinationPath: "../teamrouter/src/index.js")
        let rCLI = router.url.appendingPathComponent("teamrouter").path
        try FileManager.default.createSymbolicLink(atPath: rCLI, withDestinationPath: rBin.appendingPathComponent("teamrouter").path)
        #expect(TeamClaudePool.packageDir(cli: rCLI, installDir: "/nowhere")
            == URL(fileURLWithPath: router.dir).resolvingSymlinksInPath().path)

        // A shim leads nowhere near the package: the copy in the npm prefix is used when there is one.
        let shim = pool.url.appendingPathComponent("shim").path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: shim))
        #expect(TeamClaudePool.packageDir(cli: shim, installDir: pool.url.path) == pool.dir)
        #expect(TeamClaudePool.packageDir(cli: shim, installDir: "/nowhere") == nil)
    }

    @Test func aReloadAsksTheRunningProxyOverHTTP() async throws {
        let server = try await StubServer(statusCode: 200)
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        let ok = await TeamClaudePool.reload(dashboard: "http://127.0.0.1:\(server.port)/teamclaude/dashboard",
                                             apiKey: "made-up-key", session: session)
        #expect(ok)
        let req = try #require(await server.nextRequest())
        #expect(req.method == "POST")
        #expect(req.path == "/teamclaude/reload")
        #expect(req.headers["x-api-key"] == "made-up-key")
    }

    @Test func reloadHonorsTeamRouterPrefixAndStatusPortAndReportsErrors() async throws {
        let server = try await StubServer(statusCode: 200)
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        let routerOK = await TeamClaudePool.reload(
            dashboard: "http://127.0.0.1:9999/teamrouter/dashboard",
            session: session)
        #expect(!routerOK)

        let portOverrideOK = await TeamClaudePool.reload(
            dashboard: "http://127.0.0.1:3456/teamclaude/dashboard",
            port: Int(server.port), session: session)
        #expect(portOverrideOK)
        let first = try #require(await server.nextRequest())
        #expect(first.path == "/teamclaude/reload")
        #expect(first.headers["x-api-key"] == nil)

        let routerServer = try await StubServer(statusCode: 401, body: #"{"ok":false}"#)
        defer { routerServer.stop() }
        let unauthorized = await TeamClaudePool.reload(
            dashboard: "http://127.0.0.1:\(routerServer.port)/teamrouter/dashboard",
            session: session)
        #expect(!unauthorized)
        let second = try #require(await routerServer.nextRequest())
        #expect(second.path == "/teamrouter/reload")
    }
}
