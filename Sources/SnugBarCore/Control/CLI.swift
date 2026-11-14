import Foundation

/// What the `snugbar` command line asks for.
public enum CLIInvocation: Equatable, Sendable {
    /// Print help: general, or for one command.
    case help(ControlCommand?)
    case run(CLIOptions)
}

public struct CLIOptions: Equatable, Sendable {
    public var request: ControlRequest
    /// Print the response JSON instead of text.
    public var json: Bool
    public var port: Int?
    /// Token file to read instead of the default one.
    public var tokenFile: String?

    public init(request: ControlRequest, json: Bool = false, port: Int? = nil, tokenFile: String? = nil) {
        self.request = request
        self.json = json
        self.port = port
        self.tokenFile = tokenFile
    }
}

public struct CLIUsageError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// The command the error is about, for pointing at its help.
    public var command: ControlCommand?

    public init(_ message: String, command: ControlCommand? = nil) {
        self.message = message
        self.command = command
    }

    public var description: String { message }
}

/// Parses `snugbar <command> [arguments] [--json] [--port N]`. Options may come anywhere; `--` ends them.
public enum CLIParser {
    public static func parse(_ arguments: [String]) -> Result<CLIInvocation, CLIUsageError> {
        var positional: [String] = []
        var json = false, help = false
        var port: Int?
        var tokenFile: String?
        var flags: [String: String] = [:]  // command options: section, before, after
        var command: ControlCommand?

        var i = 0
        var optionsEnded = false
        func value(_ name: String, inline: String?) throws -> String {
            if let inline { return inline }
            i += 1
            guard i < arguments.count else { throw CLIUsageError("\(name) needs a value", command: command) }
            return arguments[i]
        }
        do {
            while i < arguments.count {
                let arg = arguments[i]
                defer { i += 1 }
                if optionsEnded || !arg.hasPrefix("-") || arg == "-" {
                    positional.append(arg)
                    if command == nil, positional.count == 1 { command = ControlCommand(rawValue: arg) }
                    continue
                }
                if arg == "--" { optionsEnded = true; continue }
                let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                let name = parts[0]
                let inline = parts.count == 2 ? parts[1] : nil
                switch name {
                case "--json": json = true
                case "-h", "--help": help = true
                case "--port", "-p":
                    let text = try value(name, inline: inline)
                    guard let n = Int(text), (1...65535).contains(n) else {
                        throw CLIUsageError("--port needs a number from 1 to 65535, not '\(text)'", command: command)
                    }
                    port = n
                case "--token-file":
                    tokenFile = try value(name, inline: inline)
                case "--section", "-s", "--before", "--after":
                    let key = name == "-s" ? "section" : String(name.dropFirst(2))
                    flags[key] = try value(name, inline: inline)
                default:
                    throw CLIUsageError("unknown option '\(arg)'", command: command)
                }
            }
        } catch let e as CLIUsageError {
            return .failure(e)
        } catch {
            return .failure(CLIUsageError("\(error)"))
        }

        guard let first = positional.first else {
            return help ? .success(.help(nil)) : .failure(CLIUsageError("missing command"))
        }
        if first == "help" {
            guard positional.count <= 2 else { return .failure(CLIUsageError("help takes at most one command")) }
            guard positional.count == 2 else { return .success(.help(nil)) }
            guard let c = ControlCommand(rawValue: positional[1]) else {
                return .failure(CLIUsageError("unknown command '\(positional[1])'"))
            }
            return .success(.help(c))
        }
        guard let command else { return .failure(CLIUsageError("unknown command '\(first)'")) }
        if help { return .success(.help(command)) }

        let words = Array(positional.dropFirst())
        let joined = words.joined(separator: " ")
        var args = ControlArguments()
        func usage(_ message: String) -> Result<CLIInvocation, CLIUsageError> {
            .failure(CLIUsageError(message, command: command))
        }
        let allowedFlags: Set<String>
        switch command {
        case .list:
            allowedFlags = ["section"]
            guard words.count <= 1 else { return usage("list takes at most one section") }
            if let s = words.first {
                guard flags["section"] == nil else { return usage("give the section once") }
                args.section = s
            } else {
                args.section = flags["section"]
            }
            if let s = args.section, Section(controlName: s) == nil {
                return usage("unknown section '\(s)'; use shown, hidden or alwaysHidden")
            }
        case .show, .hide, .click:
            allowedFlags = []
            guard !words.isEmpty else { return usage("\(command.rawValue) needs an item") }
            args.item = joined
        case .move:
            // Each word is one item (quote names with spaces); the last word is the section unless --section is given.
            allowedFlags = ["section"]
            let items: [String]
            if let s = flags["section"] {
                items = words
                args.section = s
            } else {
                items = Array(words.dropLast())
                args.section = words.last
            }
            guard !items.isEmpty else { return usage("move needs at least one item and a section") }
            if items.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return usage("move got an empty item") }
            if items.count == 1 { args.item = items[0] } else { args.items = items }
            if let s = args.section, Section(controlName: s) == nil {
                return usage("unknown section '\(s)'; use shown, hidden or alwaysHidden")
            }
        case .order:
            allowedFlags = ["before", "after"]
            guard !words.isEmpty else { return usage("order needs an item") }
            guard (flags["before"] == nil) != (flags["after"] == nil) else {
                return usage("order needs exactly one of --before <item> or --after <item>")
            }
            args.item = joined
            args.before = flags["before"]
            args.after = flags["after"]
        case .zen:
            allowedFlags = []
            guard words.count <= 1 else { return usage("zen takes on, off or toggle") }
            if let s = words.first {
                guard ["on", "off", "toggle"].contains(s.lowercased()) else { return usage("zen takes on, off or toggle, not '\(s)'") }
                args.state = s.lowercased()
            }
        case .search:
            allowedFlags = []
            guard !joined.trimmingCharacters(in: .whitespaces).isEmpty else { return usage("search needs a query") }
            args.query = joined
        case .expand, .collapse, .toggle, .swap, .status:
            allowedFlags = []
            guard words.isEmpty else { return usage("\(command.rawValue) takes no arguments") }
        }
        if let extra = flags.keys.sorted().first(where: { !allowedFlags.contains($0) }) {
            return usage("\(command.rawValue) has no --\(extra) option")
        }
        return .success(.run(CLIOptions(request: ControlRequest(command, args), json: json, port: port, tokenFile: tokenFile)))
    }
}

// MARK: - Help

public enum CLIHelp {
    public static func usage(_ command: ControlCommand) -> String {
        switch command {
        case .list: return "snugbar list [--section shown|hidden|alwaysHidden]"
        case .show, .hide, .click: return "snugbar \(command.rawValue) <item>"
        case .move: return "snugbar move <item>... <section>"
        case .order: return "snugbar order <item> --before <item> | --after <item>"
        case .zen: return "snugbar zen [on|off|toggle]"
        case .search: return "snugbar search <query>"
        case .expand, .collapse, .toggle, .swap, .status: return "snugbar \(command.rawValue)"
        }
    }

    public static var general: String {
        let width = ControlCommand.allCases.map(\.rawValue.count).max() ?? 8
        let commands = ControlCommand.allCases.map { c in
            "  " + c.rawValue.padding(toLength: width + 2, withPad: " ", startingAt: 0) + c.summary
        }.joined(separator: "\n")
        return """
            snugbar controls SnugBar, the menu bar manager, from the command line.

            Usage: snugbar <command> [arguments] [--json] [--port N]

            Commands:
            \(commands)

            <item> is an item ID (see snugbar list), an app's bundle ID, or part of an app or item name.
            Sections: shown, hidden, alwaysHidden. Moving an item moves all items of its app.

            Options:
              --json        Print the JSON response instead of text.
              --port N      Connect to port N (default: the port in SnugBar's settings, else \(ControlServerSettings.defaultPort)).
              -h, --help    Show this help. snugbar <command> --help shows help for one command.

            Exit status: 0 success, 1 the command failed, 2 usage error, 3 SnugBar not reachable.
            SnugBar must be running with its control server on (Settings > Control). When an access token is
            required, snugbar reads it from ~/Library/Application Support/SnugBar/token.

            """
    }

    public static func command(_ command: ControlCommand) -> String {
        var text = "Usage: \(usage(command)) [--json] [--port N]\n\n\(command.summary)\n"
        if command == .move {
            text += """
                The last argument is the section. Each other argument is one item; quote names that contain spaces.
                Every item is looked up first: if one isn't found or matches several items, nothing moves.

                """
        }
        let examples: [String]
        switch command {
        case .list: examples = ["snugbar list", "snugbar list --section hidden", "snugbar list --json"]
        case .show: examples = ["snugbar show com.example.chat", "snugbar show chat"]
        case .hide: examples = ["snugbar hide chat"]
        case .click: examples = ["snugbar click \"Meters: CPU\"", "snugbar click status:com.example.meters::CPU"]
        case .move:
            examples = ["snugbar move chat shown", "snugbar move chat weather hidden",
                        "snugbar move com.example.vpn \"Meters: CPU\" alwaysHidden"]
        case .order: examples = ["snugbar order clipboard --before meters", "snugbar order chat --after module:WiFi"]
        case .zen: examples = ["snugbar zen on", "snugbar zen off", "snugbar zen"]
        case .search: examples = ["snugbar search cpu"]
        case .expand, .collapse, .toggle, .swap, .status: examples = ["snugbar \(command.rawValue)"]
        }
        text += "\nExamples:\n" + examples.map { "  " + $0 }.joined(separator: "\n") + "\n"
        return text
    }
}

// MARK: - Output

/// Human-readable output for a response.
public enum CLIFormatter {
    public struct Output: Equatable, Sendable {
        public var stdout: String
        public var stderr: String
    }

    public static func format(_ response: ControlResponse, for request: ControlRequest) -> Output {
        guard response.ok else { return Output(stdout: "", stderr: error(response.error)) }
        let a = request.arguments
        switch request.command {
        case .list:
            let items = response.items ?? []
            if items.isEmpty {
                let section = a.section.flatMap(Section.init(controlName:))
                return out(section.map { "No items in \(title($0))." } ?? "No items.")
            }
            return out(table(items))
        case .search:
            let items = response.items ?? []
            return out(items.isEmpty ? "No items match '\(response.query ?? a.query ?? "")'." : table(items))
        case .status:
            return out(status(response))
        case .show:
            return out("Showing \(response.id ?? a.item ?? "the item"); it hides again after the auto-hide delay.")
        case .hide:
            return out("Hid \(response.id ?? a.item ?? "the item").")
        case .click:
            return out("Opened \(response.id ?? a.item ?? "the item").")
        case .move:
            let moved = response.moved ?? []
            let section = response.section.map(title) ?? a.section ?? "?"
            let noun = moved.count == 1 ? "item" : "items"
            return out((["Moved \(moved.count) \(noun) to \(section):"] + moved.map { "  " + $0 }).joined(separator: "\n"))
        case .order:
            let side = a.before != nil ? "before" : "after"
            let anchor = a.before ?? a.after ?? "?"
            return out("Placed \(response.id ?? a.item ?? "the item") \(side) '\(anchor)' (\(arranger(response.method))).")
        case .expand, .collapse, .toggle, .swap, .zen:
            return out(stateLine(response))
        }
    }

    /// The error for stderr, with candidates when the reference was ambiguous.
    public static func error(_ error: ControlError?) -> String {
        guard let error else { return "snugbar: the command failed\n" }
        var text = "snugbar: \(error.message)\n"
        if let candidates = error.candidates, !candidates.isEmpty {
            let rows = candidates.map { [$0.name, $0.id] }
            text += columns(rows, header: nil).map { "  " + $0 }.joined(separator: "\n") + "\n"
        }
        return text
    }

    static func out(_ text: String) -> Output { Output(stdout: text + "\n", stderr: "") }

    public static func title(_ section: Section) -> String {
        switch section {
        case .shown: return "Shown"
        case .hidden: return "Hidden"
        case .alwaysHidden: return "Always Hidden"
        }
    }

    static func table(_ items: [ControlItem]) -> String {
        let rows = items.map { item in
            [item.name.isEmpty ? item.app : item.name, title(item.section),
             item.overflowed ? "overflow" : (item.visible ? "yes" : "no"), item.id]
        }
        return columns(rows, header: ["NAME", "SECTION", "VISIBLE", "ID"]).joined(separator: "\n")
    }

    /// Left-aligned columns separated by two spaces; the last column isn't padded.
    static func columns(_ rows: [[String]], header: [String]?) -> [String] {
        let all = (header.map { [$0] } ?? []) + rows
        guard let count = all.first?.count else { return [] }
        let widths = (0..<count).map { c in all.map { $0[c].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { c, cell in
                c == count - 1 ? cell : cell.padding(toLength: widths[c], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
    }

    static func stateLine(_ r: ControlResponse) -> String {
        var parts: [String] = []
        if r.zen == true {
            parts.append("Zen mode is on: every app's items are hidden.")
        } else {
            switch r.state ?? .collapsed {
            case .collapsed: parts.append("Hidden items are hidden.")
            case .expanded: parts.append("Hidden items are shown.")
            case .all: parts.append("Hidden and always-hidden items are shown.")
            }
            if r.swapped == true { parts.append("Shown and Hidden are swapped.") }
        }
        return parts.joined(separator: " ")
    }

    static func arranger(_ method: String?) -> String {
        switch method {
        case "orderFile": return "order file"
        case "drag": return "⌘-drag"
        case nil, "none": return "unavailable"
        case let other?: return other
        }
    }

    static func status(_ r: ControlResponse) -> String {
        func granted(_ b: Bool?) -> String { b == true ? "granted" : "not granted" }
        var state = r.state?.rawValue ?? "unknown"
        if r.swapped == true { state += ", swapped" }
        if r.zen == true { state += ", Zen mode on" }
        let hider: String
        switch r.hider {
        case "assessment": hider = "whole apps (system)"
        case "overflowDivider": hider = "divider"
        case let other: hider = other ?? "unknown"
        }
        let rows = [
            ["Version:", r.version ?? "unknown"],
            ["State:", state],
            ["Hiding:", hider],
            ["Arranging:", arranger(r.arranger)],
            ["Accessibility:", granted(r.permissions?.accessibility)],
            ["Screen Recording:", granted(r.permissions?.screenRecording)],
            ["Menu bar folder:", granted(r.permissions?.menuBarFolder)],
            ["Server:", r.port.map { "127.0.0.1:\($0)" } ?? "unknown"],
            ["Token:", r.token == true ? "required" : "not required"],
        ]
        return columns(rows, header: nil).joined(separator: "\n")
    }
}
