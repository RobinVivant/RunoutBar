import Foundation

/// Locates TeamClaude/TeamRouter's package directory on disk and triggers config reloads via the proxy's control route.
public enum TeamClaudePool {
    /// The package a CLI belongs to: the enclosing package matching an allowed package name, or the copy in `installDir`.
    public static func packageDir(cli: String, installDir: String, fileManager: FileManager = .default) -> String? {
        var dir = URL(fileURLWithPath: AppConfig.expand(cli)).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<3 {
            let pkgURL = dir.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkgURL),
               let name = (try? JSONValue.parse(data))?["name"]?.string,
               TeamClaudeUpdates.allowedPackages.contains(name) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }
        // A shim, as Volta's, does not lead to the package. The copy in this app's npm prefix may be it.
        let base = URL(fileURLWithPath: AppConfig.expand(installDir))
        for pkg in TeamClaudeUpdates.allowedPackages {
            let candidate = base.appendingPathComponent("node_modules/\(pkg)")
            if fileManager.fileExists(atPath: candidate.appendingPathComponent("package.json").path) {
                return candidate.path
            }
        }
        return nil
    }

    /// Have the running proxy read its config again via `POST /teamclaude/reload` (or `/teamrouter/reload`).
    /// TeamClaude's Claude login does this automatically; its Codex login does not, so the app notifies it.
    public static func reload(dashboard: String, port: Int? = nil, apiKey: String? = nil,
                              session: URLSession = .shared, timeout: TimeInterval = 10) async -> Bool {
        guard let base = ClaudeResets.controlBaseURL(dashboard: dashboard, port: port),
              let url = ClaudeResets.endpoint(base: base, route: "reload",
                                              prefix: ClaudeResets.routePrefix(dashboard: dashboard)) else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return (200...299).contains(http.statusCode)
    }
}
