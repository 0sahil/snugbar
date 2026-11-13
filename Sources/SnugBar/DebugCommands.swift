import AppKit
import ApplicationServices
import SnugBarCore
import SnugBarEngine

/// Parsed `--debug <command> [args] --out <file>` arguments.
struct DebugInvocation {
    let command: String
    let arguments: [String]
    let outputURL: URL?

    init?(arguments all: [String]) {
        guard let i = all.firstIndex(of: "--debug"), i + 1 < all.count else { return nil }
        var rest = Array(all[(i + 1)...])
        command = rest.removeFirst()
        var out: URL?
        if let o = rest.firstIndex(of: "--out") {
            if o + 1 < rest.count {
                out = URL(fileURLWithPath: rest[o + 1])
                rest.removeSubrange(o...(o + 1))
            } else {
                rest.remove(at: o)
            }
        }
        outputURL = out
        arguments = rest
    }

    /// Value following a flag, e.g. `--before X`.
    func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    /// Arguments that are neither flags nor flag values.
    func positional(flagsWithValues: Set<String> = []) -> [String] {
        var result: [String] = []
        var skip = false
        for arg in arguments {
            if skip { skip = false; continue }
            if flagsWithValues.contains(arg) { skip = true; continue }
            if arg.hasPrefix("--") { continue }
            result.append(arg)
        }
        return result
    }
}

/// Runs one debug command and writes `{command, ok, error, startedAt, finishedAt, result}` as JSON.
@MainActor
struct DebugRunner {
    let invocation: DebugInvocation

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private let reader = MenuBarReader()
    private let orderFile = OrderFileAccess()

    init(invocation: DebugInvocation) {
        self.invocation = invocation
    }

    func run() async -> Int32 {
        let started = Date()
        var result: (any Encodable)?
        var failure: String?
        do {
            result = try await dispatch()
        } catch let e as Failure {
            failure = e.description
        } catch {
            failure = String(describing: error)
        }
        let code: Int32 = failure == nil ? 0 : 1
        let envelope = Envelope(
            command: invocation.command, arguments: invocation.arguments, ok: failure == nil, error: failure,
            startedAt: started, finishedAt: Date(), result: result.map(AnyEncodable.init)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(envelope)
            data.append(0x0A)
            if let url = invocation.outputURL {
                try AtomicFile.write(data, to: url)
            } else {
                FileHandle.standardOutput.write(data)
            }
        } catch {
            FileHandle.standardError.write(Data("could not write output: \(error)\n".utf8))
            return 3
        }
        return code
    }

    private func dispatch() async throws -> any Encodable {
        switch invocation.command {
        case "status": return status()
        case "list": return try list()
        case "hide": return try await hide()
        case "click": return try await click()
        case "move": return try await move()
        case "capture": return try await capture()
        case "order-file": return try dumpOrderFile()
        case "close-overflow": return await closeOverflow()
        case "expanded-row": return await expandedRow()
        case "row-state": return await rowState()
        default:
            throw Failure("unknown command '\(invocation.command)'; use status, list, hide, click, move, capture or order-file")
        }
    }

    // MARK: - status

    struct StatusResult: Encodable {
        struct AppInfo: Encodable { var bundleID: String?; var version: String?; var pid: Int32 }
        struct OSInfo: Encodable { var version: String; var build: String? }
        struct HiderInfo: Encodable { var backend: HiderBackend; var available: Bool; var lastError: String? }
        struct ScreenInfo: Encodable {
            var name: String
            var frame: Rect
            var backingScale: Double
            var notchRightAreaMinX: Double?
        }
        var app: AppInfo
        var macOS: OSInfo
        var permissions: Permissions.Status
        var hiders: [HiderInfo]
        var menuBarAgentRunning: Bool
        var screens: [ScreenInfo]
    }

    private func status() -> StatusResult {
        let assessment = AssessmentHider()
        let divider = OverflowDividerHider()
        return StatusResult(
            app: .init(
                bundleID: Bundle.main.bundleIdentifier,
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                pid: ProcessInfo.processInfo.processIdentifier
            ),
            macOS: .init(version: SystemInfo.version, build: SystemInfo.build),
            permissions: Permissions.status(orderFile: orderFile),
            hiders: [
                .init(backend: assessment.backend, available: assessment.isAvailable, lastError: assessment.lastError),
                .init(backend: divider.backend, available: divider.isAvailable, lastError: divider.lastError),
            ],
            menuBarAgentRunning: reader.agentPID != nil,
            screens: NSScreen.screens.map { s in
                .init(
                    name: s.localizedName,
                    frame: Rect(x: s.frame.minX, y: s.frame.minY, width: s.frame.width, height: s.frame.height),
                    backingScale: Double(s.backingScaleFactor),
                    notchRightAreaMinX: s.auxiliaryTopRightArea.map { Double($0.minX) }
                )
            }
        )
    }

    // MARK: - list

    struct ListedItem: Encodable {
        var item: MenuBarItem
        var indexInApp: Int
        var idFromOrderFile: Bool
        var section: Section
    }

    struct ListResult: Encodable {
        var orderFileUsed: Bool
        var overflowIndicator: Rect?
        var count: Int
        var items: [ListedItem]
    }

    private func requireAccessibility() throws {
        guard Permissions.accessibility else { throw Failure("accessibility not granted") }
    }

    private func snapshot() throws -> (MenuBarSnapshot, [String: Double]?) {
        try requireAccessibility()
        let positions = try? orderFile.readPositions()
        let snap = reader.snapshot(orderPositions: positions)
        if let problem = snap.problem { throw Failure(problem) }
        return (snap, positions)
    }

    private func list() throws -> ListResult {
        let (snap, positions) = try snapshot()
        let settings = (try? SettingsStore(url: SettingsStore.defaultURL).load()) ?? .default
        let items = snap.entries.map {
            ListedItem(item: $0.item, indexInApp: $0.indexInApp, idFromOrderFile: $0.item.id.isOrderFileKey,
                       section: settings.sections.section(for: $0.item))
        }
        return ListResult(
            orderFileUsed: positions != nil,
            overflowIndicator: snap.overflowIndicatorFrame.map { Rect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
            count: items.count,
            items: items
        )
    }

    // MARK: - hide

    struct HideResult: Encodable {
        var backend: HiderBackend
        var seconds: Double
        var kept: [String]
        var allowedSystemItems: String
        var before: [String]
        var during: [String]
        var after: [String]
        var hiddenDuring: [String]
        var restoredAfter: Bool
        var hiderError: String?
        var guardEvents: [NotificationCenterGuard.Event]
    }

    /// `hide <seconds> [bundle ids to keep] [--backend assessment|divider]`
    private func hide() async throws -> HideResult {
        try requireAccessibility()
        let positional = invocation.positional(flagsWithValues: ["--backend"])
        guard let first = positional.first, let seconds = Double(first), seconds > 0 else {
            throw Failure("usage: hide <seconds> [bundle ids to keep] [--backend assessment|divider]")
        }
        var kept = Set(positional.dropFirst())
        if let own = Bundle.main.bundleIdentifier { kept.insert(own) }

        let assessment = AssessmentHider()
        let divider = OverflowDividerHider()
        let hider: Hider
        switch invocation.value(after: "--backend") {
        case "divider": hider = divider
        case "assessment", nil:
            hider = assessment.isAvailable ? assessment : divider
        case let other?:
            throw Failure("unknown backend '\(other)'")
        }

        let ids = { (s: MenuBarSnapshot) in s.items.map(\.id.rawValue) }
        let positions = try? orderFile.readPositions()
        let before = ids(reader.snapshot(orderPositions: positions))

        var guardian: NotificationCenterGuard?
        if hider === divider {
            divider.install()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        try hider.hide(allowing: kept)
        if hider === assessment {
            let g = NotificationCenterGuard(hider: assessment, reader: reader)
            g.start()
            guardian = g
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let during = ids(reader.snapshot(orderPositions: positions))
        if seconds > 1 { try? await Task.sleep(nanoseconds: UInt64((seconds - 1) * 1_000_000_000)) }

        guardian?.stop()
        hider.show()
        if hider === divider { divider.uninstall() }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let after = ids(reader.snapshot(orderPositions: positions))

        return HideResult(
            backend: hider.backend,
            seconds: seconds,
            kept: kept.sorted(),
            allowedSystemItems: hider === assessment ? "0..<64" : "n/a",
            before: before,
            during: during,
            after: after,
            hiddenDuring: before.filter { !during.contains($0) },
            restoredAfter: Set(after) == Set(before),
            hiderError: hider.lastError,
            guardEvents: guardian?.events ?? []
        )
    }

    // MARK: - click

    struct ClickResult: Encodable {
        var item: MenuBarItem
        var activation: ItemActivator.Result
    }

    private func findItem(_ query: String, in snap: MenuBarSnapshot) throws -> MenuBarItem {
        switch ItemQuery.find(query, in: snap.items) {
        case let .success(item): return item
        case let .failure(f): throw Failure(f.description)
        }
    }

    private func click() async throws -> ClickResult {
        guard let query = invocation.positional().first else { throw Failure("usage: click <item>") }
        let (snap, positions) = try snapshot()
        let item = try findItem(query, in: snap)
        let activator = ItemActivator(reader: reader, hider: AssessmentHider())
        let result = try await activator.activate(item, orderPositions: positions)
        // Stay alive briefly: when this short-lived process quits, focus changes can dismiss the menu it opened.
        let linger = Double(invocation.value(after: "--linger") ?? "3") ?? 3
        try? await Task.sleep(nanoseconds: UInt64(linger * 1_000_000_000))
        return ClickResult(item: item, activation: result)
    }

    // MARK: - move

    struct MoveResult: Encodable {
        var item: ItemID
        var anchor: ItemID
        var placement: String
        var arrangement: Arranger.Result
    }

    /// `move <item> --before <item>` or `move <item> --after <item>`
    private func move() async throws -> MoveResult {
        let usage = "usage: move <item> --before <item> | --after <item>"
        guard let query = invocation.positional(flagsWithValues: ["--before", "--after"]).first else { throw Failure(usage) }
        let (snap, _) = try snapshot()
        let item = try findItem(query, in: snap)
        let placement: Arranger.Placement
        let placementName: String
        if let q = invocation.value(after: "--before") {
            placement = .before(try findItem(q, in: snap))
            placementName = "before"
        } else if let q = invocation.value(after: "--after") {
            placement = .after(try findItem(q, in: snap))
            placementName = "after"
        } else {
            throw Failure(usage)
        }
        let anchor: MenuBarItem
        switch placement {
        case let .before(a), let .after(a): anchor = a
        }
        let arranger = Arranger(reader: reader, access: orderFile)
        arranger.forceDrag = invocation.arguments.contains("--drag")
        let result = try await arranger.move(item, placement)
        return MoveResult(item: item.id, anchor: anchor.id, placement: placementName, arrangement: result)
    }

    // MARK: - capture

    struct CaptureResult: Encodable {
        struct Saved: Encodable { var id: ItemID; var file: String; var source: ItemImager.Source }
        var directory: String
        var screenRecording: Bool
        var captureMilliseconds: Int?
        var captureError: String?
        var saved: [Saved]
        var missing: [ItemID]
    }

    /// `capture <dir>`
    private func capture() async throws -> CaptureResult {
        guard let path = invocation.positional().first else { throw Failure("usage: capture <dir>") }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (snap, _) = try snapshot()
        let imager = ItemImager()
        var captured: Set<ItemID> = []
        var captureError: String?
        do {
            captured = Set(try await imager.refresh(snap.items))
        } catch {
            captureError = String(describing: error)
        }
        var saved: [CaptureResult.Saved] = []
        var missing: [ItemID] = []
        for (i, item) in snap.items.enumerated() {
            guard let image = imager.image(for: item, capturedNow: captured), let png = image.image.pngData() else {
                missing.append(item.id)
                continue
            }
            let name = String(format: "%02d-", i) + Self.fileSafe(item.id.rawValue) + ".png"
            let url = dir.appendingPathComponent(name)
            try png.write(to: url)
            saved.append(.init(id: item.id, file: url.path, source: image.source))
        }
        return CaptureResult(
            directory: dir.path,
            screenRecording: Permissions.screenRecording,
            captureMilliseconds: imager.lastCaptureDuration.map { Int($0 * 1000) },
            captureError: captureError,
            saved: saved,
            missing: missing
        )
    }

    static func fileSafe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    // MARK: - order-file

    struct OrderFileResult: Encodable {
        var file: String
        var leftToRight: [String]
        var positions: [String: Double]
    }

    struct ExpandedRowResult: Encodable { var opened: Bool; var windows: [[String]]; var closed: Bool }

    private func expandedRow() async -> ExpandedRowResult {
        let opened = await reader.clickOverflowButton(open: true)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let windows = reader.debugExpandedWindows()
        let closed = await reader.clickOverflowButton(open: false)
        return ExpandedRowResult(opened: opened, windows: windows, closed: closed)
    }

    struct RowStateResult: Encodable { var closed: [String]; var open: [String]; var closedAgain: [String]; var states: [String] }

    /// Debug: on-screen windows near the menu bar, with the row closed, open, and closed again.
    private func rowState() async -> RowStateResult {
        func windows() -> [String] { reader.debugAgentWindows() }
        var states = ["start: \(String(describing: reader.isOverflowRowOpen()))"]
        let closed = windows()
        states.append("open ok: \(await reader.setOverflowRow(open: true)) -> \(String(describing: reader.isOverflowRowOpen()))")
        try? await Task.sleep(nanoseconds: 900_000_000)
        let open = windows()
        let shot = Process(); shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-R", "0,0,1470,34", "/tmp/rowstate-open.png"]; try? shot.run(); shot.waitUntilExit()
        states.append("close ok: \(await reader.setOverflowRow(open: false)) -> \(String(describing: reader.isOverflowRowOpen()))")
        return RowStateResult(closed: closed, open: open, closedAgain: windows(), states: states)
    }

    struct CloseOverflowResult: Encodable { var clicked: Bool }

    /// Clicks MenuBarAgent's » to close the overflow row (pointer put back).
    private func closeOverflow() async -> CloseOverflowResult {
        CloseOverflowResult(clicked: await reader.setOverflowRow(open: false))
    }

    private func dumpOrderFile() throws -> OrderFileResult {
        let positions = try orderFile.readPositions()
        return OrderFileResult(
            file: (try? orderFile.plistURL().path) ?? "",
            leftToRight: OrderPlanner.leftToRight(positions),
            positions: positions
        )
    }
}

private struct Envelope: Encodable {
    var command: String
    var arguments: [String]
    var ok: Bool
    var error: String?
    var startedAt: Date
    var finishedAt: Date
    var result: AnyEncodable?
}

private struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
