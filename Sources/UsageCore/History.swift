import Foundation

public struct Sample: Codable, Sendable, Hashable {
    public var time: Date
    /// Percent used per window id.
    public var values: [String: Double]

    public init(time: Date, values: [String: Double]) {
        self.time = time
        self.values = values
    }

    enum CodingKeys: String, CodingKey { case time = "t", values = "v" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .time))
        values = try c.decode([String: Double].self, forKey: .values)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode((time.timeIntervalSince1970 * 10).rounded() / 10, forKey: .time)
        try c.encode(values, forKey: .values)
    }
}

/// Usage samples per account, kept for eight days so a full weekly window fits.
public struct History: Codable, Sendable {
    public var accounts: [String: [Sample]] = [:]

    public static let retention: TimeInterval = 8 * 86_400
    /// A sample is kept when a value changed, or at least this often while flat.
    public static let heartbeat: TimeInterval = 600

    public init(accounts: [String: [Sample]] = [:]) {
        self.accounts = accounts
    }

    public func samples(_ account: String) -> [Sample] { accounts[account] ?? [] }

    /// Record fresh readings. Stale or unknown accounts add nothing, so a gap
    /// stays a gap instead of a flat line of old numbers.
    public mutating func record(_ snapshots: [AccountSnapshot], now: Date) {
        for snapshot in snapshots where !snapshot.isStale(at: now) {
            var values: [String: Double] = [:]
            for window in snapshot.windows {
                if let used = window.used { values[window.id] = used }
            }
            guard !values.isEmpty else { continue }
            var list = accounts[snapshot.id] ?? []
            if let last = list.last, last.values == values, now.timeIntervalSince(last.time) < Self.heartbeat {
                continue
            }
            list.append(Sample(time: now, values: values))
            accounts[snapshot.id] = list
        }
        prune(now: now)
    }

    public mutating func prune(now: Date) {
        for (account, list) in accounts {
            let kept = list.filter { now.timeIntervalSince($0.time) <= Self.retention }
            accounts[account] = kept.isEmpty ? nil : kept
        }
    }

    public mutating func merge(_ other: History) {
        for (account, list) in other.accounts {
            accounts[account] = ((accounts[account] ?? []) + list).sorted { $0.time < $1.time }
        }
    }

    public static func load(from url: URL) -> History? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(History.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
