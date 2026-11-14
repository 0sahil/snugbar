import Foundation
import SnugBarCore

// `snugbar <command> [arguments] [--json] [--port N]`: everything lives in SnugBarCore's CLIRunner.
exit(CLIRunner.run(CLIRunner.Context(arguments: Array(CommandLine.arguments.dropFirst()))))
