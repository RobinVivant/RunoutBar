import Foundation

/// What TeamClaude's config says while its proxy cannot be asked, and the reload one of its logins leaves out.
/// As with resets, a small Node script loads TeamClaude's own config loader from its install, so the config
/// and the credentials in it stay in that child process: the script prints a count or a verdict, nothing else.
public enum TeamClaudePool {
    /// The package a CLI belongs to: the folder above the `src/index.js` that its link leads to.
    public static func packageDir(cli: String, installDir: String, fileManager: FileManager = .default) -> String? {
        let entry = URL(fileURLWithPath: AppConfig.expand(cli)).resolvingSymlinksInPath()
        let source = entry.deletingLastPathComponent()
        if entry.lastPathComponent == "index.js", source.lastPathComponent == "src" {
            return source.deletingLastPathComponent().path
        }
        // A shim, as Volta's, does not lead to the package. The copy in this app's npm prefix may be it.
        let packaged = ClaudeResets.packageDir(installDir: installDir)
        return fileManager.fileExists(atPath: packaged + "/src/config.js") ? packaged : nil
    }

    static func arguments(packageDir: String, action: String) -> [String] {
        ["--input-type=module", "-e", script, packageDir, action]
    }

    static func ask(node: String, packageDir: String, action: String, environment: [String: String],
                    timeout: TimeInterval) async -> JSONValue? {
        guard let result = try? await Shell.run(node, arguments(packageDir: packageDir, action: action),
                                                environment: environment, timeout: timeout),
              let line = result.output.split(separator: "\n").last else { return nil }
        return try? JSONValue.parse(Data(line.utf8))
    }

    /// The accounts in the pool, of every provider: none before a first login has written the config, nil
    /// when it cannot be told. A proxy with none exits as it starts.
    public static func accountCount(node: String, packageDir: String, environment: [String: String],
                                    timeout: TimeInterval = 15) async -> Int? {
        let answer = await ask(node: node, packageDir: packageDir, action: "count", environment: environment,
                               timeout: timeout)
        guard answer?["ok"]?.bool == true else { return nil }
        return answer?["accounts"]?.int
    }

    /// Have the running proxy read its config again. TeamClaude's login does this for a Claude account; its
    /// Codex login does not, and the proxy would keep the old sign-in until a restart. False when the proxy
    /// did not confirm.
    public static func reload(node: String, packageDir: String, environment: [String: String],
                              timeout: TimeInterval = 15) async -> Bool {
        await ask(node: node, packageDir: packageDir, action: "reload", environment: environment,
                  timeout: timeout)?["ok"]?.bool == true
    }

    /// Runs as `node --input-type=module -e <script> <teamclaude package dir> count|reload`.
    static let script = #"""
    import { writeSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    import { join } from 'node:path';

    // stdout carries the one JSON answer; whatever the loaded modules print goes to stderr.
    console.log = console.error;
    const [dir, action] = process.argv.slice(1);
    const out = answer => { writeSync(1, JSON.stringify(answer) + '\n'); process.exit(0); };
    const fail = error => out({ ok: false, error: String(error).slice(0, 200) });
    process.on('unhandledRejection', err => fail(err?.message || err));

    try {
      const config = await import(pathToFileURL(join(dir, 'src', 'config.js')).href);
      if (typeof config.loadConfig !== 'function') fail('this TeamClaude version has no loadConfig');
      // No file yet is an empty pool: the first login creates it.
      const settings = await config.loadConfig();
      if (action === 'count') {
        out({ ok: true, accounts: Array.isArray(settings?.accounts) ? settings.accounts.length : 0 });
      } else if (action === 'reload') {
        const port = settings?.proxy?.port;
        if (!Number.isInteger(port)) fail('the config names no proxy port');
        // The same request TeamClaude's own commands send after they change the config.
        const reply = await fetch(`http://localhost:${port}/teamclaude/reload`, {
          method: 'POST', headers: { 'x-api-key': settings.proxy?.apiKey || '' }, signal: AbortSignal.timeout(8000),
        });
        out({ ok: reply.ok, status: reply.status });
      } else {
        fail('unknown action');
      }
    } catch (err) {
      fail(err?.message || err);
    }
    """#
}
