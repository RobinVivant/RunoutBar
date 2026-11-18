import Foundation
import Testing
@testable import RunoutCore

private struct Limited: RateLimitError, Equatable {
    var rateLimited = true
    var retryAt: Date?
}

private struct Broken: Error {}

/// What the calls did, in order, with times.
private actor Recorder {
    private(set) var events: [(name: String, at: Date)] = []
    private(set) var running = 0
    private(set) var peak = 0

    func note(_ name: String) { events.append((name, Date())) }
    func enter() { running += 1; peak = max(peak, running) }
    func leave() { running -= 1 }
    func count(_ name: String) -> Int { events.filter { $0.name == name }.count }
    var names: [String] { events.map(\.name) }
    func time(_ name: String, _ occurrence: Int = 0) -> Date? {
        let matches = events.filter { $0.name == name }
        return matches.indices.contains(occurrence) ? matches[occurrence].at : nil
    }
}

private func policy(spacing: TimeInterval = 0, backoff: TimeInterval = 0.2, maxWait: TimeInterval = 5) -> APIQueue.Policy {
    var policy = APIQueue.Policy()
    policy.spacing = spacing
    policy.backoff = backoff
    policy.maxBackoff = 1
    policy.margin = 0.02
    policy.maxWait = maxWait
    return policy
}

/// Waits until the queue reports a state that satisfies `condition`.
private func waitFor(_ queue: APIQueue, timeout: TimeInterval = 3,
                     _ condition: @Sendable (APIQueue.Snapshot) -> Bool) async -> APIQueue.Snapshot? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let snapshot = await queue.snapshot()
        if condition(snapshot) { return snapshot }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

@Suite struct APIQueueTests {
    @Test func sendsOneCallAtATimeInOrder() async throws {
        let queue = APIQueue(policy: policy())
        let recorder = Recorder()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    try await queue.run(lane: name, label: name) {
                        await recorder.enter()
                        await recorder.note(name)
                        try await Task.sleep(for: .milliseconds(40))
                        await recorder.leave()
                    }
                }
                // Join in a known order.
                _ = await waitFor(queue) { $0.entries.contains { $0.label == name } }
            }
            try await group.waitForAll()
        }
        #expect(await recorder.names == ["a", "b", "c"])
        #expect(await recorder.peak == 1)
        #expect(await queue.snapshot().entries.isEmpty)
    }

    @Test func aRateLimitedCallWaitsForTheRetryTimeThenGoesAgain() async throws {
        let queue = APIQueue(policy: policy())
        let recorder = Recorder()
        let retryAt = Date().addingTimeInterval(0.4)
        async let result: String = queue.run(lane: "acct", label: "read") {
            await recorder.note("try")
            if await recorder.count("try") == 1 { throw Limited(retryAt: retryAt) }
            return "listing"
        }
        // While it waits, the queue says so, with the time the server named plus the margin.
        let held = await waitFor(queue) { $0.entry(lane: "acct")?.state != .sending && $0.holds["acct"] != nil }
        let entry = try #require(held?.entry(lane: "acct"))
        #expect(entry.state == .held(until: retryAt.addingTimeInterval(0.02)))
        #expect(entry.attempts == 1)
        #expect(held?.nextRelease == retryAt.addingTimeInterval(0.02))

        #expect(try await result == "listing")
        #expect(await recorder.count("try") == 2)
        let second = try #require(await recorder.time("try", 1))
        #expect(second >= retryAt)
        let after = await queue.snapshot()
        #expect(after.entries.isEmpty && after.holds.isEmpty)
    }

    @Test func otherLanesKeepMovingWhileOneIsHeld() async throws {
        let queue = APIQueue(policy: policy())
        let recorder = Recorder()
        let retryAt = Date().addingTimeInterval(0.5)
        async let slow: Void = queue.run(lane: "a", label: "a") {
            await recorder.note("a")
            if await recorder.count("a") == 1 { throw Limited(retryAt: retryAt) }
        }
        _ = await waitFor(queue) { $0.holds["a"] != nil }
        // Same lane: waits behind the hold. Other lane: goes now.
        async let behind: Void = queue.run(lane: "a", label: "a2") { await recorder.note("a2") }
        _ = await waitFor(queue) { $0.entries.count == 2 }
        try await queue.run(lane: "b", label: "b") { await recorder.note("b") }
        #expect(Date() < retryAt)
        let waiting = await queue.snapshot()
        #expect(waiting.entries.map(\.label) == ["a", "a2"])
        #expect(waiting.entries.allSatisfy { if case .held = $0.state { true } else { false } })

        try await slow
        try await behind
        // The held call keeps its place in line ahead of the one that joined after it.
        #expect(await recorder.names == ["a", "b", "a", "a2"])
    }

    @Test func withoutARetryTimeTheHoldDoublesEachTime() async throws {
        let queue = APIQueue(policy: policy(backoff: 0.15))
        let recorder = Recorder()
        try await queue.run(lane: "acct", label: "read") {
            await recorder.note("try")
            if await recorder.count("try") < 3 { throw Limited(retryAt: nil) }
        }
        let first = try #require(await recorder.time("try", 0))
        let second = try #require(await recorder.time("try", 1))
        let third = try #require(await recorder.time("try", 2))
        #expect(second.timeIntervalSince(first) >= 0.15)
        #expect(third.timeIntervalSince(second) >= 0.3)
        // A success clears the strikes: the next rate limit starts from the base hold again.
        let start = Date()
        try await queue.run(lane: "acct", label: "read") {
            await recorder.note("again")
            if await recorder.count("again") == 1 { throw Limited(retryAt: nil) }
        }
        #expect(Date().timeIntervalSince(start) < 0.3)
    }

    @Test func givesUpWithTheRateLimitErrorPastTheLongestWait() async throws {
        let queue = APIQueue(policy: policy(maxWait: 0.3))
        let recorder = Recorder()
        let far = Date().addingTimeInterval(30)
        await #expect(throws: Limited.self) {
            try await queue.run(lane: "acct", label: "read") {
                await recorder.note("try")
                throw Limited(retryAt: far)
            }
        }
        #expect(await recorder.count("try") == 1)
        // The lane stays held, so the next call on it waits instead of hitting the limit again.
        #expect(await queue.snapshot().holds["acct"] != nil)
        // A call that will not wait at all gives up the same way.
        await #expect(throws: Limited.self) {
            try await queue.run(lane: "other", label: "read", maxWait: 0) { throw Limited(retryAt: nil) }
        }
    }

    @Test func cancellingStopsTheWaitAndFreesTheLine() async throws {
        let queue = APIQueue(policy: policy())
        let recorder = Recorder()
        let far = Date().addingTimeInterval(3)  // inside the longest wait, so the call is held, not dropped
        let task = Task {
            try await queue.run(lane: "acct", label: "spend") {
                await recorder.note("try")
                throw Limited(retryAt: far)
            }
        }
        _ = await waitFor(queue) { $0.holds["acct"] != nil && $0.entry(lane: "acct")?.state != .sending }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await recorder.count("try") == 1)
        #expect(await queue.snapshot().entries.isEmpty)
        #expect(Date() < far)
        // Another lane is not stuck behind the cancelled call.
        try await queue.run(lane: "b", label: "b") { await recorder.note("b") }
        #expect(await recorder.count("b") == 1)
    }

    @Test func otherErrorsPassThroughWithoutARetry() async throws {
        let queue = APIQueue(policy: policy())
        let recorder = Recorder()
        await #expect(throws: Broken.self) {
            try await queue.run(lane: "acct", label: "read") {
                await recorder.note("try")
                throw Broken()
            }
        }
        // A rate-limit error type that says "not rate-limited" is an ordinary failure too.
        await #expect(throws: Limited.self) {
            try await queue.run(lane: "acct", label: "read") {
                await recorder.note("try")
                throw Limited(rateLimited: false, retryAt: nil)
            }
        }
        #expect(await recorder.count("try") == 2)
        #expect(await queue.snapshot().holds.isEmpty)
    }

    @Test func leavesAPauseBetweenSends() async throws {
        let queue = APIQueue(policy: policy(spacing: 0.25))
        let recorder = Recorder()
        try await queue.run(lane: "a", label: "a") { await recorder.note("a") }
        try await queue.run(lane: "b", label: "b") { await recorder.note("b") }
        let first = try #require(await recorder.time("a"))
        let second = try #require(await recorder.time("b"))
        #expect(second.timeIntervalSince(first) >= 0.24)
    }

    @Test func reportsEveryChange() async throws {
        let queue = APIQueue(policy: policy())
        let retryAt = Date().addingTimeInterval(0.2)
        let recorder = Recorder()
        let watcher = Task {
            var seen: [APIQueue.State?] = []
            for await snapshot in queue.updates {
                seen.append(snapshot.entries.first?.state)
                if snapshot.entries.isEmpty, snapshot.holds.isEmpty, seen.count > 1 { break }
            }
            return seen
        }
        try await queue.run(lane: "acct", label: "read") {
            await recorder.note("try")
            if await recorder.count("try") == 1 { throw Limited(retryAt: retryAt) }
        }
        let seen = await watcher.value
        #expect(seen.contains(.sending))
        #expect(seen.contains(.held(until: retryAt.addingTimeInterval(0.02))))
        #expect(seen.last == .some(nil))
    }
}
