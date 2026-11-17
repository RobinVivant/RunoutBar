import Foundation

/// How one account looks in the app. Every field is optional.
public struct AccountStyle: Codable, Sendable, Hashable {
    public var letter: String?
    public var label: String?
    /// SF Symbol name.
    public var symbol: String?
    /// "#rrggbb".
    public var color: String?
    /// Confirmed exemption from the 5-hour session window (for example a verified
    /// Ultra subscription). A fresh 5-hour reading still shows if one appears.
    public var noFiveHourLimit: Bool?

    public init(letter: String? = nil, label: String? = nil, symbol: String? = nil, color: String? = nil,
                noFiveHourLimit: Bool? = nil) {
        self.letter = letter
        self.label = label
        self.symbol = symbol
        self.color = color
        self.noFiveHourLimit = noFiveHourLimit
    }
}

/// Resolved display identity for an account.
public struct AccountIdentity: Sendable, Hashable {
    public var letter: String
    public var label: String
    public var symbol: String
    public var color: String
}

/// User configuration, read from ~/.config/usage-bar/config.json. Missing keys
/// fall back to defaults that match a standard TeamClaude install.
public struct AppConfig: Codable, Sendable {
    public var accounts: [String: AccountStyle] = [:]
    /// Display order of account keys; accounts not listed follow in proxy order.
    public var order: [String]?
    public var teamclaude = "~/.local/bin/teamclaude"
    /// Directory holding the npm install of TeamClaude (`node_modules/@karpeleslab/teamclaude`).
    public var teamclaudeInstallDir = "~/.local/share/teamclaude"
    public var npm = "/opt/homebrew/bin/npm"
    /// Node used to read and spend Claude resets through TeamClaude's own modules.
    public var node = "/opt/homebrew/bin/node"
    public var proxyService = "com.karpeleslab.teamclaude"
    public var proxyLog = "~/Library/Logs/teamclaude.log"
    public var dashboard = "http://127.0.0.1:3456/teamclaude/dashboard"
    /// Path to `codex`; nil searches the usual locations. Set to "" to hide the Codex row.
    public var codex: String?
    /// Work days and hours for the pool run-out projection; its last day's end is the target.
    public var workWeek = WorkWeek()

    public static let codexKey = "openai"
    public static let palette = ["#0a84ff", "#bf5af2", "#30d1b2", "#ff6482", "#ffd60a", "#64d2ff", "#ff9f0a"]

    public init() {}

    enum CodingKeys: String, CodingKey {
        case accounts, order, teamclaude, teamclaudeInstallDir, npm, node, proxyService, proxyLog, dashboard, codex, workWeek
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        accounts = try c.decodeIfPresent([String: AccountStyle].self, forKey: .accounts) ?? [:]
        order = try c.decodeIfPresent([String].self, forKey: .order)
        teamclaude = try c.decodeIfPresent(String.self, forKey: .teamclaude) ?? defaults.teamclaude
        teamclaudeInstallDir = try c.decodeIfPresent(String.self, forKey: .teamclaudeInstallDir)
            ?? defaults.teamclaudeInstallDir
        npm = try c.decodeIfPresent(String.self, forKey: .npm) ?? defaults.npm
        node = try c.decodeIfPresent(String.self, forKey: .node) ?? defaults.node
        proxyService = try c.decodeIfPresent(String.self, forKey: .proxyService) ?? defaults.proxyService
        proxyLog = try c.decodeIfPresent(String.self, forKey: .proxyLog) ?? defaults.proxyLog
        dashboard = try c.decodeIfPresent(String.self, forKey: .dashboard) ?? defaults.dashboard
        codex = try c.decodeIfPresent(String.self, forKey: .codex)
        workWeek = try c.decodeIfPresent(WorkWeek.self, forKey: .workWeek) ?? defaults.workWeek
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/usage-bar/config.json")
    }

    /// The configuration, plus a readable error when the file exists but is invalid.
    public static func load(from url: URL = defaultURL) -> (config: AppConfig, error: String?) {
        guard let data = try? Data(contentsOf: url) else { return (AppConfig(), nil) }
        do {
            return (try JSONDecoder().decode(AppConfig.self, from: data), nil)
        } catch {
            return (AppConfig(), "Invalid \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    public func noFiveHourLimit(_ account: String) -> Bool { accounts[account]?.noFiveHourLimit == true }

    public func identity(for account: String, provider: Provider, index: Int) -> AccountIdentity {
        let style = accounts[account]
        let fallbackLabel = provider == .codex ? "Codex" : String(account.split(separator: "@").first ?? Substring(account))
        let label = style?.label ?? fallbackLabel
        return AccountIdentity(
            letter: style?.letter ?? String(label.prefix(1)).uppercased(),
            label: label,
            symbol: style?.symbol ?? (provider == .codex ? "terminal" : "person.crop.circle"),
            color: style?.color ?? Self.palette[index % Self.palette.count]
        )
    }

    /// Accounts in display order: configured order first, then the rest as given.
    public func ordered(_ snapshots: [AccountSnapshot]) -> [AccountSnapshot] {
        guard let order else { return snapshots }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshots.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? order.count + a.offset
            let rb = rank[b.element.id] ?? order.count + b.offset
            return ra < rb
        }.map(\.element)
    }
}
