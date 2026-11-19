import AppKit
import RunoutCore

// A Codex app server that exits early must not take this process down with it.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--snapshot"), index + 1 == arguments.count {
        // Without a folder this must not fall through to the live app, which acts on the real setup.
        FileHandle.standardError.write(Data("usage: RunoutBar --snapshot <folder> [--demo]\n".utf8))
        exit(2)
    } else if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
        // Render every screen to PNG files, then exit: live data, or made-up data with --demo.
        app.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: arguments[index + 1])
        Task { @MainActor in
            await SnapshotRunner.run(into: directory)
            exit(0)
        }
        app.run()
    } else {
        if !arguments.contains("--demo") { carryOverLegacyInstall() }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// Version 1.0 was called "Usage Bar": moves its config and history to the current folders, copies
/// its settings and stops a copy that is still running, so an update keeps everything.
@MainActor
func carryOverLegacyInstall() {
    let config = AppConfig.defaultURL.deletingLastPathComponent()
    LegacyInstall.move(config.deletingLastPathComponent().appendingPathComponent(LegacyInstall.configFolder), to: config)
    let support = AppModel.supportDir
    LegacyInstall.move(support.deletingLastPathComponent().appendingPathComponent(LegacyInstall.supportFolder),
                       to: support)
    guard let id = Bundle.main.bundleIdentifier else { return }
    let defaults = UserDefaults.standard
    let legacy = defaults.persistentDomain(forName: LegacyInstall.bundleID) ?? [:]
    for (key, value) in LegacyInstall.settingsToCopy(from: legacy, into: defaults.persistentDomain(forName: id) ?? [:]) {
        defaults.set(value, forKey: key)
    }
    NSRunningApplication.runningApplications(withBundleIdentifier: LegacyInstall.bundleID).forEach { $0.terminate() }
}
