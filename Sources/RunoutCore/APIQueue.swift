import Foundation

/// An error that can say "the server refused this call for now".
public protocol RateLimitError: Error {
    var rateLimited: Bool { get }
    /// When the server said to come back, if it did.
    var retryAt: Date? { get }
}

/// One line for every call to a rate-limited API. Calls go out one at a time, in the order they
/// joined. When the server rate-limits a call, its lane (the calls that share that limit) is held
/// until the limit clears, and the call is sent again by itself; calls on other lanes keep moving.
/// `updates` reports what is waiting and why, for the interface.
public actor APIQueue {
    public struct Policy: Sendable {
        /// Pause between two sends.
        public var spacing: TimeInterval = 1
        /// Hold after a rate limit that names no retry time. It doubles with each one in a row on a lane.
        public var backoff: TimeInterval = 60
        public var maxBackoff: TimeInterval = 300
        /// Added to the server's retry time, so the retry does not land on its edge.
        public var margin: TimeInterval = 1
        /// A call gives up when its next try would start later than this after it joined.
        public var maxWait: TimeInterval = 600

        public init() {}
    }

    public enum State: Sendable, Equatable {
        /// Behind another call.
        case queued
        /// Its lane is rate-limited until this time.
        case held(until: Date)
        case sending
    }

    public struct Entry: Identifiable, Sendable, Equatable {
        public var id: UUID
        public var lane: String
        public var label: String
        public var state: State
        /// Times this call has been sent.
        public var attempts: Int

        public init(id: UUID = UUID(), lane: String, label: String, state: State, attempts: Int = 0) {
            self.id = id
            self.lane = lane
            self.label = label
            self.state = state
            self.attempts = attempts
        }
    }

    public struct Snapshot: Sendable, Equatable {
        /// Calls in the order they joined.
        public var entries: [Entry] = []
        /// Lanes under a rate limit, and when each clears.
        public var holds: [String: Date] = [:]

        public init() {}

        public func entry(lane: String) -> Entry? { entries.first { $0.lane == lane } }

        /// The soonest time a held call goes out again.
        public var nextRelease: Date? {
            entries.compactMap { if case .held(let until) = $0.state { until } else { nil } }.min()
        }
    }

    private struct Job {
        let id: UUID
        let lane: String
        let label: String
        let joined: Date
        var attempts = 0
        var sending = false
        /// Set while the job waits for its turn.
        var turn: CheckedContinuation<Void, Error>?
    }

    /// Every change to the queue. One consumer.
    public nonisolated let updates: AsyncStream<Snapshot>
    private let publisher: AsyncStream<Snapshot>.Continuation
    private let policy: Policy
    private var jobs: [Job] = []
    private var holds: [String: Date] = [:]
    /// Rate limits in a row per lane, for the backoff.
    private var strikes: [String: Int] = [:]
    private var inFlight = false
    private var lastSend: Date?
    private var timer: Task<Void, Never>?
    private var published = Snapshot()

    public init(policy: Policy = Policy()) {
        self.policy = policy
        (updates, publisher) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func snapshot() -> Snapshot { current() }

    /// Sends `operation` when its turn comes and returns its result. A rate-limited try is repeated
    /// after the limit clears, for up to `maxWait` (the policy's when nil); past that, the rate-limit
    /// error is thrown. Any other error is thrown at once. Cancelling the task stops the wait.
    public func run<T: Sendable>(lane: String, label: String, maxWait: TimeInterval? = nil,
                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        let joined = Date()
        jobs.append(Job(id: id, lane: lane, label: label, joined: joined))
        defer {
            jobs.removeAll { $0.id == id }
            pump()
        }
        while true {
            try await waitForTurn(id)
            do {
                let value = try await operation()
                landed(id)
                strikes[lane] = nil
                return value
            } catch let error as RateLimitError where error.rateLimited {
                landed(id)
                let until = hold(lane, retryAt: error.retryAt)
                if until.timeIntervalSince(joined) > maxWait ?? policy.maxWait { throw error }
            } catch {
                landed(id)
                throw error
            }
        }
    }

    /// A send came back: the line is free again.
    private func landed(_ id: UUID) {
        inFlight = false
        lastSend = Date()
        if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].sending = false }
    }

    private func hold(_ lane: String, retryAt: Date?) -> Date {
        let now = Date()
        strikes[lane, default: 0] += 1
        let until: Date
        if let retryAt, retryAt > now {
            until = retryAt.addingTimeInterval(policy.margin)
        } else {
            let doubled = policy.backoff * pow(2, Double(strikes[lane, default: 1] - 1))
            until = now.addingTimeInterval(min(doubled, policy.maxBackoff))
        }
        holds[lane] = max(until, holds[lane] ?? .distantPast)
        return holds[lane] ?? until
    }

    private func waitForTurn(_ id: UUID) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled, let index = jobs.firstIndex(where: { $0.id == id }) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                jobs[index].turn = continuation
                pump()
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    private func abandon(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), let turn = jobs[index].turn else { return }
        jobs[index].turn = nil
        turn.resume(throwing: CancellationError())
    }

    /// Gives the turn to the first waiting call whose lane is clear, or sets a timer for the moment
    /// one can go. Runs after every change.
    private func pump() {
        timer?.cancel()
        timer = nil
        let now = Date()
        holds = holds.filter { $0.value > now }
        var wake = holds.values.min()
        if !inFlight, let index = jobs.firstIndex(where: { $0.turn != nil && holds[$0.lane] == nil }) {
            if let last = lastSend, last.addingTimeInterval(policy.spacing) > now {
                wake = min(wake ?? .distantFuture, last.addingTimeInterval(policy.spacing))
            } else {
                let turn = jobs[index].turn
                jobs[index].turn = nil
                jobs[index].sending = true
                jobs[index].attempts += 1
                inFlight = true
                turn?.resume()
            }
        }
        publish()
        if let wake {
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.01, wake.timeIntervalSinceNow)))
                if !Task.isCancelled { await self?.pump() }
            }
        }
    }

    private func current() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.holds = holds
        snapshot.entries = jobs.map { job in
            let state: State = job.sending ? .sending : holds[job.lane].map { .held(until: $0) } ?? .queued
            return Entry(id: job.id, lane: job.lane, label: job.label, state: state, attempts: job.attempts)
        }
        return snapshot
    }

    private func publish() {
        let snapshot = current()
        guard snapshot != published else { return }
        published = snapshot
        publisher.yield(snapshot)
    }
}
