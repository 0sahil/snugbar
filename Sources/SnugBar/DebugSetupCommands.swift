import AppKit
import SnugBarCore
import SnugBarEngine

/// Read-only setup and permission commands. None creates a status item, touches the hider, asks for a permission or
/// reads or writes the settings file; permissions given with `--grants` are made up.
///
/// - `setup-snapshot --step <step> --grants <list|none> --out <png> [--restart-hint] [--appearance light|dark]`:
///   renders the setup window offscreen.
/// - `menu-snapshot --grants <list|none> --out <txt>`: SnugBar's menu as text (title, enabled, state, second line),
///   built without a status item.
/// - `availability --grants <list|none> --out <json>`: what works with those permissions.
/// - `permissions --out <json>`: this copy's real permission status (no prompt).
extension DebugRunner {
    /// `--grants accessibility,screenRecording,orderFile` or `none`.
    func grants(required: Bool = true) throws -> PermissionGrants? {
        guard let value = invocation.value(after: "--grants") else {
            if required { throw Failure("--grants needs none or a comma list of accessibility, screenRecording, orderFile") }
            return nil
        }
        guard let grants = PermissionGrants(list: value) else {
            throw Failure("unknown permission in '\(value)'; use none or a comma list of accessibility, screenRecording, orderFile")
        }
        return grants
    }

    // MARK: - setup-snapshot

    struct SetupSnapshotResult: Encodable {
        var image: String
        var step: String
        var grants: String
        var windowTitle: String
        var contentSize: [Double]
        var imagePixels: [Int]
        var progress: String?
        var forwardButton: String?
        var reducedModeNote: Bool
        var restartHint: Bool
    }

    func setupSnapshot() async throws -> SetupSnapshotResult {
        let usage = "usage: setup-snapshot --step <\(SetupStep.allCases.map(\.rawValue).joined(separator: "|"))> --grants <list|none> --out <png> [--restart-hint] [--appearance light|dark]"
        guard let name = invocation.value(after: "--step"), let step = SetupStep(name: name), let out = invocation.outputURL else {
            throw Failure(usage)
        }
        let grants = try grants() ?? .none
        let controller = AppController(preview: .default, grants: grants)
        if invocation.arguments.contains("--restart-hint") { controller.previewRestartHint() }
        let model = SetupModel(step: step)

        let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: SetupView.size),
                                     styleMask: SetupWindow.styleMask, backing: .buffered, defer: false)
        applyAppearance(window)
        SetupWindow.configure(window, model: model, controller: controller)
        let rep = try await render(window, to: out)
        let size = window.contentRect(forFrameRect: window.frame).size
        return withExtendedLifetime((controller, model)) {
            SetupSnapshotResult(
                image: out.path, step: step.rawValue, grants: grants.listDescription, windowTitle: window.title,
                contentSize: [size.width, size.height], imagePixels: [rep.pixelsWide, rep.pixelsHigh],
                progress: model.flow.progressText, forwardButton: model.flow.forwardTitle(grants: grants),
                reducedModeNote: model.flow.showsReducedModeNote(grants: grants) || (step == .done && !grants.accessibility),
                restartHint: controller.screenRecordingRestartHint.shows(granted: grants.screenRecording)
            )
        }
    }

    func applyAppearance(_ window: NSWindow) {
        switch invocation.value(after: "--appearance") {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    /// Orders the window in far outside every screen, lets SwiftUI lay it out, and writes the window (title bar
    /// included) as a PNG.
    func render(_ window: NSWindow, to out: URL) async throws -> NSBitmapImageRep {
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let content = window.contentView else { throw Failure("the window has no content view") }
        let view = content.superview ?? content
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure("could not make a bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("could not encode the PNG") }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out, options: .atomic)
        return rep
    }

    // MARK: - menu-snapshot

    struct MenuSnapshotResult: Encodable {
        struct Entry: Encodable {
            var title: String
            var separator: Bool
            var enabled: Bool
            var state: String?
            var subtitle: String?
            var keyEquivalent: String?
        }

        var text: String
        var grants: String
        var entries: [Entry]
    }

    func menuSnapshot() throws -> MenuSnapshotResult {
        guard let out = invocation.outputURL else { throw Failure("usage: menu-snapshot --grants <list|none> --out <txt>") }
        let grants = try grants() ?? .none
        let controller = AppController(preview: .default, grants: grants)
        let menu = StatusMenu.build(controller: controller) {}
        // Validation as AppKit does it when the menu opens: closure items are enabled unless set otherwise.
        menu.update()
        let entries = menu.items.map { item -> MenuSnapshotResult.Entry in
            .init(title: item.title, separator: item.isSeparatorItem, enabled: item.isEnabled,
                  state: item.state == .on ? "on" : nil, subtitle: item.subtitle,
                  keyEquivalent: item.keyEquivalent.isEmpty ? nil : item.keyEquivalent)
        }
        var lines = ["SnugBar menu, grants: \(grants.listDescription)"]
        for e in entries {
            if e.separator { lines.append("----"); continue }
            var line = (e.state == "on" ? "[x] " : "    ") + e.title
            if !e.enabled { line += "  (disabled)" }
            if let key = e.keyEquivalent { line += "  [key \(key)]" }
            lines.append(line)
            if let subtitle = e.subtitle { lines.append("        " + subtitle) }
        }
        let text = lines.joined(separator: "\n") + "\n"
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: out, options: .atomic)
        return withExtendedLifetime(controller) { MenuSnapshotResult(text: out.path, grants: grants.listDescription, entries: entries) }
    }

    // MARK: - availability

    struct AvailabilityResult: Encodable {
        var grants: PermissionGrants
        var reducedMode: Bool
        var unavailable: [AppFeature]
        var features: [FeatureAvailability.Entry]
    }

    func availabilityReport() throws -> AvailabilityResult {
        let grants = try grants() ?? .none
        let availability = FeatureAvailability(grants: grants)
        return AvailabilityResult(grants: grants, reducedMode: availability.isReduced, unavailable: availability.unavailable,
                                  features: availability.entries)
    }

    // MARK: - permissions

    struct PermissionsResult: Encodable {
        var bundlePath: String
        var accessibility: Bool
        var screenRecording: Bool
        var orderFile: OrderFileAccess.Status
        var reducedMode: Bool
        var unavailable: [AppFeature]
    }

    func permissionsReport() -> PermissionsResult {
        let status = Permissions.status(orderFile: orderFile)
        let availability = FeatureAvailability(accessibility: status.accessibility, screenRecording: status.screenRecording,
                                               orderFile: status.orderFileAccess == .granted)
        return PermissionsResult(bundlePath: Bundle.main.bundlePath, accessibility: status.accessibility,
                                 screenRecording: status.screenRecording, orderFile: status.orderFileAccess,
                                 reducedMode: availability.isReduced, unavailable: availability.unavailable)
    }
}
