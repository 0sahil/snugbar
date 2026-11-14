import AppKit
import SnugBarCore

// Run as `snugbar` (the bundle's Contents/MacOS/snugbar is this binary on a case-insensitive volume, and a link may be
// named that way): be the command-line tool, never a second copy of the app.
if let name = CommandLine.arguments.first.map({ ($0 as NSString).lastPathComponent }), name == "snugbar" {
    exit(CLIRunner.run(CLIRunner.Context(arguments: Array(CommandLine.arguments.dropFirst()))))
}

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
