import CoreGraphics
import Foundation
import SnugBarCore

// Hidden: the app runs its bundled helper with this flag to learn whether Screen Recording is allowed now. Its own
// `CGPreflightScreenCaptureAccess()` keeps the first answer for the life of the process; a fresh process gets the
// current one, and TCC attributes a helper the app started to the app. Never prompts.
if Array(CommandLine.arguments.dropFirst()) == [ScreenRecordingAccess.preflightFlag] {
    print(ScreenRecordingAccess.preflightOutput(CGPreflightScreenCaptureAccess()))
    exit(0)
}

// `snugbar <command> [arguments] [--json] [--port N]`: everything lives in SnugBarCore's CLIRunner.
exit(CLIRunner.run(CLIRunner.Context(arguments: Array(CommandLine.arguments.dropFirst()))))
