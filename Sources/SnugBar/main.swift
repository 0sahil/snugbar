import AppKit

// `--debug <command> [args] --out <file>` runs one engine command headlessly, writes JSON and exits.
// Otherwise the menu bar app starts.
if let invocation = DebugInvocation(arguments: CommandLine.arguments) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        let code = await DebugRunner(invocation: invocation).run()
        exit(code)
    }
    app.run()
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // `NSApplication.delegate` is weak and Swift may release a local after its last use, so keep the delegate (and
    // everything it owns) alive for the whole run.
    withExtendedLifetime(delegate) { app.run() }
}
