import AppKit
import SnugBarCore

/// `settings-snapshot --pane <name> --out <png> [--server-off] [--grants <list|none>] [--hover] [--size WxH]
/// [--appearance light|dark]`: renders the Settings window (the same window setup as the app's) offscreen with default
/// settings at 760×520 (or `--size`) and writes a PNG; the JSON goes beside it. `--grants` fakes the permissions
/// (default: all granted); `--hover` turns on "Resting the pointer on the menu bar" so its slider shows;
/// `--icon-style` picks the menu bar icon style; `--updates-off` shows automatic update checks turned off (the updater
/// is a preview that never starts Sparkle). Nothing is started: no status item, no hiding, no server, no hotkeys, no
/// update check, and neither the settings
/// file, the token file, the order file nor the remembered pane is read or written.
extension DebugRunner {
    struct SettingsSnapshotResult: Encodable {
        struct Size: Encodable { var width: Double; var height: Double }
        var pane: String
        var image: String
        var windowTitle: String
        var contentSize: Size
        var imagePixels: Size
        /// Widths of the split view's columns (sidebar first), in points.
        var splitColumns: [Double]
        var sidebarCollapsed: Bool?
        struct SplitItem: Encodable {
            var behavior: String
            var minimumThickness: Double
            var maximumThickness: Double
            var canCollapse: Bool
            var collapsed: Bool
        }
        var splitAutosaveName: String?
        var splitItems: [SplitItem]
        var sidebarRows: Int
        var sidebarSelectedRow: Int
        var toolbarItems: [String]
        var serverState: String
        var grants: String
    }

    func settingsSnapshot() async throws -> SettingsSnapshotResult {
        let usage = "usage: settings-snapshot --pane <\(SettingsPane.allCases.map(\.rawValue).joined(separator: "|"))> --out <png> [--server-off] [--grants <list|none>] [--hover] [--icon-style chevrons|capsule] [--updates-off] [--size WxH] [--appearance light|dark]"
        guard let name = invocation.value(after: "--pane"), let pane = SettingsPane(name: name) else { throw Failure(usage) }
        guard let out = invocation.outputURL else { throw Failure(usage) }

        var settings = SnugBarCore.Settings.default
        settings.controlServer.enabled = !invocation.arguments.contains("--server-off")
        if invocation.arguments.contains("--hover") { settings.reveal.hover = true }
        if let name = invocation.value(after: "--icon-style") {
            guard let style = MenuBarIconStyle(rawValue: name) else { throw Failure(usage) }
            settings.menuBarIcon = style
        }
        let grants = try grants(required: false) ?? .all
        let controller = AppController(preview: settings, grants: grants)
        var size = SettingsWindow.defaultContentSize
        if let text = invocation.value(after: "--size") {
            let parts = text.split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2 else { throw Failure(usage) }
            size = NSSize(width: parts[0], height: parts[1])
        }
        let serverState: ControlServer.State = settings.controlServer.enabled ? .listening(port: settings.controlServer.effectivePort) : .off
        let control = ControlSurface(controller: controller, previewServerState: serverState)
        let navigation = SettingsNavigation(defaults: nil, pane: pane)

        let window = OffscreenWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindow.defaultContentSize),
            styleMask: SettingsWindow.styleMask, backing: .buffered, defer: false
        )
        switch invocation.value(after: "--appearance") {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        // A preview updater: shows the update controls, never starts Sparkle or checks anything.
        let updater = Updater(previewAutomaticChecks: !invocation.arguments.contains("--updates-off"))
        SettingsWindow.configure(window, controller: controller, control: control, updater: updater, navigation: navigation)
        window.setContentSize(size)
        // Far outside every screen, so nothing appears; ordered in so SwiftUI lays out the toolbar and split view.
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let content = window.contentView else { throw Failure("the window has no content view") }
        // The frame view includes the title bar and toolbar.
        let view = content.superview ?? content
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("could not make a bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        // The sidebar sits on a glass effect view, which `cacheDisplay` leaves blank: draw its list on the window
        // background colour instead so the rows can be checked.
        let sidebarColumn = Self.find(in: content) { String(describing: type(of: $0)).contains("SidebarStyleContext") }
        let sidebarList = sidebarColumn.flatMap { Self.find(in: $0) { $0 is NSTableView } as? NSTableView }
        if let sidebarList, let context = NSGraphicsContext(bitmapImageRep: rep) {
            let rect = sidebarList.convert(sidebarList.bounds, to: view)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            }
            // Row by row: each row's cell is its own hosting view.
            for row in sidebarList.subviews {
                for cell in [row] + row.subviews.flatMap({ [$0] + $0.subviews }) where cell.bounds.width > 0 {
                    guard let cellRep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { continue }
                    cell.cacheDisplay(in: cell.bounds, to: cellRep)
                    cellRep.draw(in: cell.convert(cell.bounds, to: view), from: .zero, operation: .sourceOver,
                                 fraction: 1, respectFlipped: false, hints: nil)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("could not encode the PNG") }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out, options: .atomic)

        if invocation.arguments.contains("--views") {
            var lines: [String] = []
            Self.describe(view, depth: 0, into: &lines)
            try Data(lines.joined(separator: "\n").utf8).write(to: out.deletingPathExtension().appendingPathExtension("views.txt"))
        }

        let split = Self.firstSplitView(in: content)
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        return withExtendedLifetime((controller, control, navigation, updater)) {
            SettingsSnapshotResult(
                pane: pane.rawValue,
                image: out.path,
                windowTitle: window.title,
                contentSize: .init(width: contentSize.width, height: contentSize.height),
                imagePixels: .init(width: Double(rep.pixelsWide), height: Double(rep.pixelsHigh)),
                splitColumns: split?.arrangedSubviews.map { Double($0.frame.width) } ?? [],
                sidebarCollapsed: split.flatMap { s in s.arrangedSubviews.first.map { s.isSubviewCollapsed($0) } },
                splitAutosaveName: split?.autosaveName,
                splitItems: ((split?.delegate as? NSSplitViewController)?.splitViewItems ?? []).map {
                    .init(behavior: "\($0.behavior.rawValue)", minimumThickness: Double($0.minimumThickness),
                          maximumThickness: Double($0.maximumThickness), canCollapse: $0.canCollapse,
                          collapsed: $0.isCollapsed)
                },
                sidebarRows: sidebarList?.numberOfRows ?? 0,
                sidebarSelectedRow: sidebarList?.selectedRow ?? -1,
                toolbarItems: window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [],
                serverState: "\(serverState)",
                grants: grants.listDescription
            )
        }
    }

    /// `--views`: the view tree (class, frame, hidden) beside the PNG as `.views.txt`.
    private static func describe(_ view: NSView, depth: Int, into lines: inout [String]) {
        guard depth < 40 else { return }
        let f = view.frame
        var line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
            + " (\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"
        if view.isHidden { line += " hidden" }
        if view.alphaValue < 1 { line += " alpha=\(view.alphaValue)" }
        if let table = view as? NSTableView { line += " rows=\(table.numberOfRows)" }
        if let field = view as? NSTextField, !field.stringValue.isEmpty { line += " \"\(field.stringValue.prefix(40))\"" }
        lines.append(line)
        for sub in view.subviews { describe(sub, depth: depth + 1, into: &lines) }
    }

    private static func firstSplitView(in view: NSView) -> NSSplitView? {
        find(in: view) { $0 is NSSplitView } as? NSSplitView
    }

    private static func find(in view: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(view) { return view }
        for sub in view.subviews {
            if let found = find(in: sub, where: match) { return found }
        }
        return nil
    }
}

/// A window that may sit outside every screen.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
