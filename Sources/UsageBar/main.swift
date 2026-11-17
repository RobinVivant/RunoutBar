import AppKit

// A Codex app server that exits early must not take this process down with it.
signal(SIGPIPE, SIG_IGN)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
        // Render every screen to PNG files, then exit: live data, or made-up data with --demo.
        app.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: arguments[index + 1])
        Task { @MainActor in
            await SnapshotRunner.run(into: directory)
            exit(0)
        }
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
