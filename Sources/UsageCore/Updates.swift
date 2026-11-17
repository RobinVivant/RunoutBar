import Foundation

public enum SemVer {
    /// Only plain x.y.z is ever passed to npm, as TeamClaude's own updater does:
    /// the registry's "latest" is untrusted network input.
    public static func isRelease(_ version: String) -> Bool {
        version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    static func parts(_ version: String) -> [Int] {
        let core = version.split(separator: "+").first.map(String.init) ?? version
        let base = core.split(separator: "-").first.map(String.init) ?? core
        return base.split(separator: ".").map { Int($0) ?? 0 }
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = parts(a), pb = parts(b)
        for index in 0..<3 {
            let x = index < pa.count ? pa[index] : 0
            let y = index < pb.count ? pb[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Checks npm for TeamClaude releases and installs one into the local npm
/// prefix the proxy runs from.
public enum TeamClaudeUpdates {
    public static let package = "@karpeleslab/teamclaude"

    public static func installedVersion(installDir: String) -> String? {
        let url = URL(fileURLWithPath: AppConfig.expand(installDir))
            .appendingPathComponent("node_modules/\(package)/package.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONValue.parse(data))?["version"]?.string
    }

    /// The registry's current "latest" dist-tag.
    public static func latestVersion(session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: URL(string: "https://registry.npmjs.org/\(package)")!)
        request.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.registry }
        guard let latest = try JSONValue.parse(data)["dist-tags"]?["latest"]?.string else { throw UpdateError.registry }
        return latest
    }

    public enum UpdateError: LocalizedError {
        case registry, badVersion(String), installFailed(String), restartFailed(String)

        public var errorDescription: String? {
            switch self {
            case .registry: return "Could not read the npm registry"
            case .badVersion(let v): return "Refusing to install \"\(v.prefix(40))\": not a release version"
            case .installFailed(let output): return "npm install failed: \(output)"
            case .restartFailed(let output): return "Proxy restart failed: \(output)"
            }
        }
    }

    /// `npm install --prefix <dir> @karpeleslab/teamclaude@<version>`. A plain
    /// `teamclaude update` would run `npm install -g` and leave this copy as is.
    public static func installArguments(version: String, installDir: String) throws -> [String] {
        guard SemVer.isRelease(version) else { throw UpdateError.badVersion(version) }
        return ["install", "--prefix", AppConfig.expand(installDir), "--no-audit", "--no-fund",
                "\(package)@\(version)"]
    }
}
