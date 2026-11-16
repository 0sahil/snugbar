import AppKit
import SnugBarCore
import SnugBarEngine

/// Read-only layout commands. None of them creates a status item, touches the hider, calls the Arranger or writes the
/// order file or the settings file.
///
/// - `layout-snapshot --fake --out <png> [--dragging] [--appearance light|dark]`: renders the layout editor offscreen
///   with made-up items in all three sections, two spacers and three apps selected (`--dragging`: mid-drag onto
///   Always Hidden).
/// - `reconcile --dry-run [--settings <path>] [--trigger <name>] [--explicit] [--live-keys a,b] [--positions <json>]
///   --out <file>`: what a reconcile would do now, as JSON.
/// - `backups [--dir <dir>] --out <file>`: the layout backups in a folder.
extension DebugRunner {
    // MARK: - layout-snapshot

    struct LayoutSnapshotResult: Encodable {
        var image: String
        var contentSize: [Double]
        var imagePixels: [Int]
        var rows: [String: [String]]
        var selected: [String]
        var dragLabel: String?
    }

    func layoutSnapshot() async throws -> LayoutSnapshotResult {
        let usage = "usage: layout-snapshot --fake --out <png> [--dragging] [--appearance light|dark]"
        guard invocation.arguments.contains("--fake"), let out = invocation.outputURL else { throw Failure(usage) }

        let demo = Self.demoLayout()
        let model = LayoutEditorModel()
        model.update(rows: demo.rows, images: demo.images, orderAccess: !invocation.arguments.contains("--no-access"))
        for key in demo.selected { model.selection.click(key, modifier: .command, rows: model.selectableRows) }

        let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: LayoutEditorWindow.defaultContentSize),
                                     styleMask: LayoutEditorWindow.styleMask, backing: .buffered, defer: false)
        switch invocation.value(after: "--appearance") {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        LayoutEditorWindow.configure(window, model: model)
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        if invocation.arguments.contains("--dragging"), let first = demo.selected.first, let row = model.rowFrames[.alwaysHidden] {
            // As if the selection had been picked up and carried over Always Hidden.
            model.dragChanged(first, location: CGPoint(x: row.midX - 60, y: row.midY))
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let content = window.contentView else { throw Failure("the window has no content view") }
        let view = content.superview ?? content
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("could not make a bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("could not encode the PNG") }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out, options: .atomic)

        let size = window.contentRect(forFrameRect: window.frame).size
        var rows: [String: [String]] = [:]
        for section in LayoutEditorModel.sections {
            rows[section.rawValue] = (model.rows[section] ?? []).map { $0.tile.isSpacer ? $0.tile.helpText : ($0.tile.items.first?.displayName ?? $0.id) }
        }
        return LayoutSnapshotResult(
            image: out.path, contentSize: [size.width, size.height], imagePixels: [rep.pixelsWide, rep.pixelsHigh], rows: rows,
            selected: model.selectedTiles.map { $0.items.first?.displayName ?? $0.key }, dragLabel: model.drag?.contents.label
        )
    }

    /// Made-up apps (example bundle IDs) with SF Symbols standing in for captured pictures. Apple's items get made-up
    /// captures as the live bar gives them (the bar's top edge in the crop), keyed as the app keys them; the clock is
    /// a wide one.
    static func demoLayout() -> (rows: [SnugBarCore.Section: [LayoutTile]], images: [String: NSImage], selected: [String]) {
        func item(_ id: String, _ bundle: String, _ app: String, _ name: String? = nil, apple: Bool = false, ax: String? = nil) -> MenuBarItem {
            MenuBarItem(id: ItemID(rawValue: id), ownerBundleID: bundle, ownerPID: 0, appName: app, displayName: name ?? app,
                        frame: Rect(x: 0, y: 0, width: 24, height: 24), isAppleItem: apple, isOverflowed: false, axIdentifier: ax)
        }
        let cc = "com.apple.controlcenter"
        let items: [(MenuBarItem, String)] = [
            (item("status:com.example.meters::CPU", "com.example.meters", "Meters", "Meters: CPU"), "cpu"),
            (item("status:com.example.meters::Memory", "com.example.meters", "Meters", "Meters: Memory"), "memorychip"),
            (item("status:org.example.clipboard::Item-0", "org.example.clipboard", "Clipboard"), "doc.on.clipboard"),
            (item("status:com.example.notes::Item-0", "com.example.notes", "Notes Bar"), "note.text"),
            (item("module:WiFi", cc, "Control Center", "Wi-Fi", apple: true, ax: "com.apple.menuextra.wifi"), "wifi"),
            (item("module:Battery", cc, "Control Center", "Battery", apple: true, ax: "com.apple.menuextra.battery"), "battery.75percent"),
            (item("module:ControlCenter", cc, "Control Center", "Control Center", apple: true, ax: AppleItems.controlCenterIdentifier), "switch.2"),
            (item("module:Clock", cc, "Control Center", "Clock", apple: true, ax: AppleItems.clockIdentifier), "clock"),
            (item("status:com.example.chat::Item-0", "com.example.chat", "Chat"), "bubble.left"),
            (item("status:com.example.weather::Item-0", "com.example.weather", "Weather"), "cloud.sun"),
            (item("status:com.example.timer::Item-0", "com.example.timer", "Timer"), "timer"),
            (item("status:com.example.sync::Item-0", "com.example.sync", "Sync"), "arrow.triangle.2.circlepath"),
            (item("status:com.example.music::Item-0", "com.example.music", "Music Bar"), "music.note"),
            (item("status:com.example.tunnel::Item-0", "com.example.tunnel", "Tunnel"), "network"),
            (item("status:com.example.backup::Item-0", "com.example.backup", "Backup"), "externaldrive"),
        ]
        let sections = AppSectionMap(apps: [
            "com.example.meters": .shown, "org.example.clipboard": .shown, "com.example.notes": .shown,
            "com.example.tunnel": .alwaysHidden, "com.example.backup": .alwaysHidden,
        ], defaultSection: .hidden)
        let s1 = LayoutSpacer(id: "00000000-0000-0000-0000-00000000000A", width: 16)
        let s2 = LayoutSpacer(id: "00000000-0000-0000-0000-00000000000B", width: 28)
        let layout = DesiredLayout(shownOrder: [
            "status:com.example.meters::CPU", "status:com.example.meters::Memory", s1.key, "status:org.example.clipboard::Item-0",
            s2.key, "status:com.example.notes::Item-0", "module:WiFi", "module:Battery",
        ], spacers: [s1, s2])
        let live = layout.shownOrder
        let rows = LayoutEditorRows.rows(items: items.map(\.0), liveShown: live, sections: sections, layout: layout) { _ in true }
        let captures: [String: NSImage] = [
            "module:WiFi": fakeCapture(symbol: "wifi", width: 22),
            "module:Battery": fakeCapture(symbol: "battery.75percent", width: 26),
            "module:ControlCenter": fakeCapture(symbol: "switch.2", width: 26),
            "module:Clock": fakeCapture(text: "Mon 16 Nov  14:05", width: 150.5),
        ]
        var images: [String: NSImage] = [:]
        for (item, symbol) in items {
            if let capture = captures[item.id.rawValue] {
                images[item.id.rawValue] = capture
                continue
            }
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()
            image.isTemplate = true
            images[item.id.rawValue] = image
        }
        let selected = ["status:com.example.chat::Item-0", "status:com.example.weather::Item-0", "status:com.example.timer::Item-0"]
        return (rows, images, selected)
    }

    // MARK: - reconcile --dry-run

    struct ReconcileReport: Encodable {
        struct Visibility: Encodable {
            var plan: String
            var allowed: [String]?
        }

        var dryRun: Bool
        var settingsFile: String
        var trigger: String
        var explicit: Bool
        var accessibility: Bool
        var orderFileReadable: Bool
        var liveItemCount: Int
        var liveShownKeys: [String]
        var savedOrder: [String]
        var enforcesOrder: Bool
        var spacers: [LayoutSpacer]
        var visibility: Visibility
        var action: LayoutReconcile.Action
        var reasons: [String]
        /// Shown's and the hidden sections' values together.
        var wouldWriteOrderFile: [String: Double]
        var sectionPlans: [String: SectionOrder.Plan]
        var savedSectionOrders: [String: [String]]
        var wouldPlaceSpacers: [String: Double]
        var wouldDrag: [OrderPlanner.Move]
        var wouldSaveOrder: [String]?
        var targetOrder: [String]?
        var renumbered: Bool?
    }

    func reconcileDryRun() throws -> ReconcileReport {
        let usage = "usage: reconcile --dry-run [--settings <path>] [--trigger <name>] [--explicit] [--live-keys a,b] [--positions <json>] --out <file>"
        guard invocation.arguments.contains("--dry-run") else { throw Failure(usage + " (only --dry-run is supported)") }
        let settingsURL = invocation.value(after: "--settings").map { URL(fileURLWithPath: $0) } ?? SettingsStore.defaultURL
        let settings = try SettingsStore(url: settingsURL).load()
        let triggerName = invocation.value(after: "--trigger") ?? LayoutTrigger.launch.rawValue
        guard LayoutTrigger(rawValue: triggerName) != nil else {
            throw Failure("unknown trigger '\(triggerName)'; use \(LayoutTrigger.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let explicit = invocation.arguments.contains("--explicit")

        var positions: [String: Double]?
        if let path = invocation.value(after: "--positions") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            positions = try JSONDecoder().decode([String: Double].self, from: data)
        } else {
            positions = try? orderFile.readPositions()
        }
        let own = Bundle.main.bundleIdentifier ?? "app.snugbar.SnugBar"
        let items = Permissions.accessibility ? reader.snapshot(orderPositions: positions).items : []
        // No spacer items exist in this process; SnugBar's own items are left out.
        let live = invocation.value(after: "--live-keys").map(ControlArguments.splitList)
            ?? LayoutReconcile.liveKeys(items, sections: settings.sections, ownBundleID: own) { _ in nil }

        var sectionKeys: [SnugBarCore.Section: [String]] = [:]
        if let positions {
            for item in items where !item.isAppleItem {
                let section = settings.sections.section(for: item)
                guard SectionOrder.sections.contains(section), let key = SectionOrder.fileKey(for: item.id, positions: positions) else { continue }
                sectionKeys[section, default: []].append(key)
            }
        }
        let evaluation = LayoutReconcile.evaluate(
            layout: settings.layout, live: live, positions: positions, ownBundleID: own, sectionKeys: sectionKeys, explicit: explicit
        )
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.activationPolicy == .prohibited ? nil : $0.bundleIdentifier })
        let visibility: ReconcileReport.Visibility
        switch VisibilityPlanner.plan(state: .initial, sections: settings.sections, candidates: running.union(settings.knownApps.keys),
                                      alwaysAllowed: [own]) {
        case .showEverything: visibility = .init(plan: "showEverything", allowed: nil)
        case let .allow(allowed): visibility = .init(plan: "allow", allowed: allowed.sorted())
        }
        let decision = evaluation.decision
        let plan = decision.plan
        return ReconcileReport(
            dryRun: true, settingsFile: settingsURL.path, trigger: triggerName, explicit: explicit,
            accessibility: Permissions.accessibility, orderFileReadable: positions != nil, liveItemCount: items.count,
            liveShownKeys: live, savedOrder: settings.layout.shownOrder, enforcesOrder: settings.layout.enforcesOrder,
            spacers: settings.layout.spacers, visibility: visibility, action: decision.action, reasons: decision.reasons,
            wouldWriteOrderFile: evaluation.fileChanges, sectionPlans: evaluation.sectionPlans,
            savedSectionOrders: [SnugBarCore.Section.hidden.rawValue: settings.layout.hiddenOrder,
                                 SnugBarCore.Section.alwaysHidden.rawValue: settings.layout.alwaysHiddenOrder],
            wouldPlaceSpacers: decision.action == .writeOrderFile ? plan?.freePositions ?? [:] : [:],
            wouldDrag: decision.action == .dragMoves ? plan?.moves ?? [] : [],
            wouldSaveOrder: evaluation.orderToSave, targetOrder: plan?.targetOrder, renumbered: plan?.renumbered
        )
    }

    // MARK: - backups

    struct BackupsResult: Encodable {
        struct Backup: Encodable {
            var path: String
            var createdAt: Date
            var systemBuild: String?
            var positions: Int
            var savedOrder: Int?
            var appSections: Int?
            var spacers: Int?
            var reason: String?
        }

        var directory: String
        var count: Int
        var backups: [Backup]
    }

    func backups() -> BackupsResult {
        let dir = invocation.value(after: "--dir").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? SnugBarPaths.backups
        let list = LayoutBackupStore(directory: dir).list()
        return BackupsResult(directory: dir.path, count: list.count, backups: list.map {
            .init(path: $0.url.path, createdAt: $0.createdAt, systemBuild: $0.systemBuild, positions: $0.positionCount,
                  savedOrder: $0.orderCount, appSections: $0.appSectionCount, spacers: $0.spacerCount, reason: $0.reason)
        })
    }
}
