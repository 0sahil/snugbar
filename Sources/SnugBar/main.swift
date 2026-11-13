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
    SnugBarApp.main()
}
