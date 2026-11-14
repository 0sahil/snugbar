import AppKit
import SnugBarCore
import SnugBarEngine
import SwiftUI

/// The layout editor's state (features 30, 31, 37, 42): three rows of tiles, the selection and a drag in progress.
/// The app wires `actions` to `AppController`; offscreen snapshots leave them empty.
@MainActor
final class LayoutEditorModel: ObservableObject {
    struct Tile: Identifiable {
        let tile: LayoutTile
        let image: NSImage?
        var id: String { tile.key }
    }

    struct DragState {
        var contents: LayoutDragContents
        /// The tile the drag started on (its image is the drag image).
        var startKey: String
        var location: CGPoint
        var target: SnugBarCore.Section?
        /// Insertion index in the target row, when it can be reordered.
        var gap: Int?
    }

    struct Actions {
        var reorder: (SnugBarCore.Section, [String], [String]) -> Void = { _, _, _ in }
        var moveApps: ([String], SnugBarCore.Section) -> Void = { _, _ in }
        var addSpacer: () -> Void = {}
        var removeSpacers: ([String]) -> Void = { _ in }
        var setSpacerWidth: (String, Double) -> Void = { _, _ in }
        var grantAccess: () -> Void = {}
        var grantScreenRecording: () -> Void = {}
        var setDragging: (Bool) -> Void = { _ in }
    }

    static let sections: [SnugBarCore.Section] = [.shown, .hidden, .alwaysHidden]

    @Published private(set) var rows: [SnugBarCore.Section: [Tile]] = [:]
    @Published var selection = LayoutSelection()
    @Published var drag: DragState?
    @Published private(set) var orderAccess = true
    /// Pictures of items are shown (Screen Recording); otherwise app icons.
    @Published private(set) var pictures = true
    /// A one-line status under the editor.
    @Published var message: String?

    /// Tile frames in the editor's coordinate space; updated by layout, not published (no redraw loop).
    var tileFrames: [String: CGRect] = [:]
    var rowFrames: [SnugBarCore.Section: CGRect] = [:]
    var actions = Actions()
    let hoverLabel = HoverLabel()
    private var hoveredKey: String?

    func update(rows: [SnugBarCore.Section: [LayoutTile]], images: [String: NSImage], orderAccess: Bool, pictures: Bool = true) {
        var result: [SnugBarCore.Section: [Tile]] = [:]
        for section in Self.sections {
            result[section] = (rows[section] ?? []).map { Tile(tile: $0, image: images[$0.key]) }
        }
        self.rows = result
        self.orderAccess = orderAccess
        self.pictures = pictures
        selection.retain(selectableRows)
    }

    /// Each section's selectable keys, left to right (locked tiles can't be selected).
    var selectableRows: [[String]] {
        Self.sections.map { (rows[$0] ?? []).filter { !$0.tile.isLocked }.map(\.id) }
    }

    func tile(_ key: String) -> LayoutTile? {
        for section in Self.sections { if let t = rows[section]?.first(where: { $0.id == key }) { return t.tile } }
        return nil
    }

    var selectedTiles: [LayoutTile] {
        selectableRows.joined().filter(selection.contains).compactMap(tile)
    }

    // MARK: - Selection

    func click(_ key: String, modifiers: NSEvent.ModifierFlags) {
        guard tile(key)?.isLocked == false else { return }
        let modifier: LayoutSelection.Modifier = modifiers.contains(.command) ? .command : modifiers.contains(.shift) ? .shift : .none
        selection.click(key, modifier: modifier, rows: selectableRows)
    }

    func selectAll() { selection.selectAll(selectableRows) }

    func clearSelection() { selection.clear() }

    /// What a right-click acts on: the selection when the tile is in it, else the tile.
    func contextTargets(for key: String) -> [LayoutTile] {
        selection.contains(key) ? selectedTiles : tile(key).map { [$0] } ?? []
    }

    // MARK: - Drag

    func dragChanged(_ key: String, location: CGPoint) {
        if drag == nil {
            guard let start = tile(key), !start.isLocked else { return }
            if !selection.contains(key) { selection.click(key, modifier: .none, rows: selectableRows) }
            let keys = selection.dragged(from: key, rows: selectableRows)
            drag = DragState(contents: LayoutDragContents(tiles: keys.compactMap(tile)), startKey: key, location: location)
            endHover()
            actions.setDragging(true)
        }
        let (target, gap) = hitTest(location)
        drag?.location = location
        drag?.target = target
        drag?.gap = gap
    }

    func dragEnded(location: CGPoint) {
        guard let state = drag else { return }
        let (target, gap) = hitTest(location)
        drag = nil
        actions.setDragging(false)
        guard let target else { return }
        let row = (rows[target] ?? []).map(\.tile)
        switch LayoutDrop.outcome(dragging: state.contents, onto: target, gap: gap, row: row) {
        case let .reorder(section, order, apps):
            message = nil
            actions.reorder(section, order, apps)
        case let .moveApps(apps, section):
            message = nil
            actions.moveApps(apps, section)
        case let .none(reason):
            if let reason { message = reason }
        }
    }

    /// Whether a row can be reordered: Shown always (the ⌘-drag fallback moves its items), Hidden and Always Hidden
    /// only through the order file (their items aren't on screen to drag).
    func canReorder(_ section: SnugBarCore.Section) -> Bool {
        section == .shown || orderAccess
    }

    /// The section under a point and, when it can be reordered, the insertion index (nearest tile's left or right
    /// side).
    func hitTest(_ point: CGPoint) -> (SnugBarCore.Section?, Int?) {
        guard let section = rowFrames.first(where: { $0.value.insetBy(dx: -8, dy: -8).contains(point) })?.key else { return (nil, nil) }
        guard canReorder(section) else { return (section, nil) }
        let movable = (rows[section] ?? []).filter { !$0.tile.isLocked }
        var best: (index: Int, distance: CGFloat, frame: CGRect)?
        for (i, tile) in movable.enumerated() {
            guard let f = tileFrames[tile.id] else { continue }
            let dx = max(f.minX - point.x, 0, point.x - f.maxX)
            let dy = max(f.minY - point.y, 0, point.y - f.maxY)
            let d = dx * dx + dy * dy * 4
            if best == nil || d < best!.distance { best = (i, d, f) }
        }
        guard let best else { return (section, 0) }
        return (section, point.x < best.frame.midX ? best.index : best.index + 1)
    }

    /// Where the insertion line goes for the current gap, in the editor's coordinates.
    var insertionLine: CGRect? {
        guard let drag, let target = drag.target, let gap = drag.gap else { return nil }
        let movable = (rows[target] ?? []).filter { !$0.tile.isLocked }
        if gap < movable.count, let f = tileFrames[movable[gap].id] {
            return CGRect(x: f.minX - 3, y: f.minY, width: 2, height: f.height)
        }
        if let last = movable.last, let f = tileFrames[last.id] {
            return CGRect(x: f.maxX + 1, y: f.minY, width: 2, height: f.height)
        }
        return rowFrames[target].map { CGRect(x: $0.minX + 10, y: $0.minY + 10, width: 2, height: 32) }
    }

    // MARK: - Hover labels

    func hoverChanged(_ key: String, text: String, rect: NSRect?, window: NSWindow?) {
        if let rect, drag == nil {
            hoveredKey = key
            hoverLabel.pointerEntered(text: text, tileRect: rect, parent: window)
        } else if hoveredKey == key {
            endHover()
        }
    }

    func endHover() {
        hoveredKey = nil
        hoverLabel.hide()
    }
}

// MARK: - Views

struct LayoutEditorView: View {
    static let minSize = CGSize(width: 640, height: 460)
    static let coordinateSpace = "layout-editor"

    @ObservedObject var model: LayoutEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drag items to reorder a section, or drag them onto another section to move their app there.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(LayoutEditorModel.sections, id: \.self) { section in
                LayoutSectionRow(model: model, section: section)
            }
            Spacer(minLength: 0)
            LayoutSelectionBar(model: model)
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: Self.minSize.width, maxWidth: .infinity, minHeight: Self.minSize.height, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(TileFrameKey.self) { frames in MainActor.assumeIsolated { model.tileFrames = frames } }
        .onPreferenceChange(RowFrameKey.self) { frames in MainActor.assumeIsolated { model.rowFrames = frames } }
        .overlay(alignment: .topLeading) { dragOverlay }
        .background {
            // ⌘A selects every tile and Esc clears the selection. SnugBar has no Edit menu to provide them.
            Group {
                Button("Select All") { model.selectAll() }.keyboardShortcut("a", modifiers: .command)
                Button("Clear Selection") { model.clearSelection() }.keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Items of one app always move together between sections. The clock and Control Center stay at the right end.")
            Text("Select several items with ⌘-click or ⇧-click to move them together.")
            if !model.orderAccess {
                HStack(spacing: 8) {
                    Text(PermissionText.layoutEditorNoFolder)
                    Button(PermissionKind.menuBarFolder.buttonTitle) { model.actions.grantAccess() }
                        .controlSize(.small)
                }
            }
            if !model.pictures {
                HStack(spacing: 8) {
                    Text(PermissionText.noScreenRecordingPictures)
                    Button(PermissionKind.screenRecording.buttonTitle) { model.actions.grantScreenRecording() }
                        .controlSize(.small)
                }
            }
            if let message = model.message {
                Text(message).foregroundStyle(.primary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var dragOverlay: some View {
        if let line = model.insertionLine {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: line.width, height: line.height)
                .offset(x: line.minX, y: line.minY)
                .allowsHitTesting(false)
        }
        if let drag = model.drag {
            LayoutDragImage(tile: model.rows.values.joined().first { $0.id == drag.startKey }, label: drag.contents.label)
                .offset(x: drag.location.x - 17, y: drag.location.y - 17)
                .allowsHitTesting(false)
        }
    }
}

/// One section: its title and a wrapping row of tiles.
private struct LayoutSectionRow: View {
    @ObservedObject var model: LayoutEditorModel
    let section: SnugBarCore.Section

    var body: some View {
        let tiles = model.rows[section] ?? []
        let isTarget = model.drag?.target == section
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title).font(.headline)
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(tiles) { tile in
                    LayoutTileView(model: model, tile: tile)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .overlay(alignment: .leading) {
                if tiles.isEmpty {
                    Text(section == .shown ? "No items" : "No apps").foregroundStyle(.tertiary).padding(.leading, 12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isTarget ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isTarget ? 2 : 1)
            )
            .background(GeometryReader { geo in
                Color.clear.preference(key: RowFrameKey.self, value: [section: geo.frame(in: .named(LayoutEditorView.coordinateSpace))])
            })
        }
    }
}

private struct LayoutTileView: View {
    static let height: CGFloat = 32
    static let width: CGFloat = 36
    static let imageSize: CGFloat = 20

    @ObservedObject var model: LayoutEditorModel
    let tile: LayoutEditorModel.Tile

    var body: some View {
        let t = tile.tile
        let selected = model.selection.contains(t.key)
        let beingDragged = model.drag?.contents.tiles.contains { $0.key == t.key } ?? false
        content
            .frame(width: t.spacer.map { max(CGFloat($0.width), 10) + 8 } ?? Self.width, height: Self.height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.22) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .opacity(t.isLocked ? 0.5 : (beingDragged ? 0.35 : 1))
            .contentShape(Rectangle())
            .background(GeometryReader { geo in
                Color.clear.preference(key: TileFrameKey.self, value: [t.key: geo.frame(in: .named(LayoutEditorView.coordinateSpace))])
            })
            .background(HoverTracker(
                onEnter: { rect, window in model.hoverChanged(t.key, text: t.helpText, rect: rect, window: window) },
                onExit: { model.hoverChanged(t.key, text: t.helpText, rect: nil, window: nil) }
            ))
            .onTapGesture { model.click(t.key, modifiers: NSEvent.modifierFlags) }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(LayoutEditorView.coordinateSpace))
                    .onChanged { model.dragChanged(t.key, location: $0.location) }
                    .onEnded { model.dragEnded(location: $0.location) },
                including: t.isLocked ? .none : .all
            )
            .contextMenu { if !t.isLocked { LayoutTileMenu(model: model, targets: model.contextTargets(for: t.key)) } }
            .accessibilityElement()
            .accessibilityLabel(t.helpText)
    }

    @ViewBuilder private var content: some View {
        if let spacer = tile.tile.spacer {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .frame(width: max(CGFloat(spacer.width), 10), height: Self.imageSize + 2)
        } else {
            TileImage(image: tile.image).frame(width: Self.imageSize, height: Self.imageSize)
        }
    }
}

/// Captured pictures (templates) take the label colour; app icons keep theirs.
private struct TileImage: View {
    let image: NSImage?

    var body: some View {
        if let image {
            if image.isTemplate {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit).foregroundStyle(.primary)
            } else {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            }
        } else {
            Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
        }
    }
}

/// The picture under the pointer while dragging, with the count when several apps move ("3 apps").
private struct LayoutDragImage: View {
    let tile: LayoutEditorModel.Tile?
    let label: String?

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let spacer = tile?.tile.spacer {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: max(CGFloat(spacer.width), 10), height: 22)
                } else {
                    TileImage(image: tile?.image).frame(width: 20, height: 20)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
            .shadow(radius: 2, y: 1)
            if let label {
                Text(label)
                    .font(.callout)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.regularMaterial))
                    .shadow(radius: 1, y: 1)
            }
        }
        .opacity(0.92)
    }
}

/// Right-click on a tile or the selection: "Move 3 Apps To" > sections, and "Remove Spacer".
private struct LayoutTileMenu: View {
    @ObservedObject var model: LayoutEditorModel
    let targets: [LayoutTile]

    var body: some View {
        let contents = LayoutDragContents(tiles: targets)
        let apps = contents.bundleIDs
        let spacers = targets.compactMap(\.spacer)
        if !apps.isEmpty {
            Menu(BulkSectionMove.submenuTitle(count: apps.count)) {
                ForEach(LayoutEditorModel.sections, id: \.self) { section in
                    Button(section.title) { model.actions.moveApps(apps, section) }
                }
            }
        }
        if !spacers.isEmpty {
            Button(spacers.count == 1 ? "Remove Spacer" : "Remove \(spacers.count) Spacers") {
                model.actions.removeSpacers(spacers.map(\.id))
            }
        }
    }
}

/// Under the rows: what is selected, "Move N Apps To…", a selected spacer's width, and "Add Spacer".
private struct LayoutSelectionBar: View {
    @ObservedObject var model: LayoutEditorModel

    var body: some View {
        let selected = model.selectedTiles
        let contents = LayoutDragContents(tiles: selected)
        let apps = contents.bundleIDs
        let spacers = selected.compactMap(\.spacer)
        HStack(spacing: 12) {
            Menu(BulkSectionMove.title(count: apps.count)) {
                ForEach(LayoutEditorModel.sections, id: \.self) { section in
                    Button(section.title) { model.actions.moveApps(apps, section) }
                }
            }
            .fixedSize()
            .disabled(apps.isEmpty)
            if let summary = summary(selected: selected, apps: apps.count, spacers: spacers.count) {
                Text(summary).foregroundStyle(.secondary)
            }
            if spacers.count == 1, selected.count == 1, let spacer = spacers.first {
                Stepper(value: Binding(
                    get: { spacer.width },
                    set: { model.actions.setSpacerWidth(spacer.id, $0) }
                ), in: LayoutSpacer.widthRange, step: 1) {
                    Text("Width: \(Int(spacer.width)) pt").monospacedDigit()
                }
                .fixedSize()
            }
            Spacer()
            Button("Add Spacer") { model.actions.addSpacer() }
        }
    }

    private func summary(selected: [LayoutTile], apps: Int, spacers: Int) -> String? {
        guard !selected.isEmpty else { return nil }
        if selected.count == 1, let only = selected.first {
            return only.isSpacer ? "Spacer selected" : "\(only.items.first?.displayName ?? "Item") selected"
        }
        var parts: [String] = []
        if apps > 0 { parts.append(apps == 1 ? "1 app" : "\(apps) apps") }
        if spacers > 0 { parts.append(spacers == 1 ? "1 spacer" : "\(spacers) spacers") }
        if parts.isEmpty { parts.append("\(selected.count) items") }
        return parts.joined(separator: ", ") + " selected"
    }
}

private struct TileFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct RowFrameKey: PreferenceKey {
    static let defaultValue: [SnugBarCore.Section: CGRect] = [:]
    static func reduce(value: inout [SnugBarCore.Section: CGRect], nextValue: () -> [SnugBarCore.Section: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Window

/// The "Layout" window: an AppKit window hosting `LayoutEditorView`.
@MainActor
enum LayoutEditorWindow {
    static let defaultContentSize = NSSize(width: 820, height: 560)
    static let autosaveName = "SnugBarLayout"
    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]

    static func configure(_ window: NSWindow, model: LayoutEditorModel) {
        let hosting = NSHostingController(rootView: LayoutEditorView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.title = "Layout"
        window.contentMinSize = LayoutEditorView.minSize
        window.setContentSize(defaultContentSize)
        window.isReleasedWhenClosed = false
    }
}

/// Opens the editor, keeps it fed while it is open (2 s poll, as the SnugBar Bar does) and stops when it closes.
@MainActor
final class LayoutEditorController: NSObject, NSWindowDelegate {
    private let controller: AppController
    private let openSettings: (SettingsPane) -> Void
    private var window: NSWindow?
    private let model = LayoutEditorModel()
    private var timer: Timer?
    private var observation: Any?

    init(controller: AppController, openSettings: @escaping (SettingsPane) -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        let c = controller
        model.actions = .init(
            reorder: { section, order, apps in c.editorReorder(section, order: order, appsIn: apps) },
            moveApps: { apps, section in c.editorMoveApps(apps, to: section) },
            addSpacer: { c.addSpacer() },
            removeSpacers: { ids in ids.forEach { c.removeSpacer(id: $0) } },
            setSpacerWidth: { id, width in c.setSpacerWidth(id: id, width) },
            grantAccess: { [weak self] in
                c.grantOrderFileAccess()
                self?.reload()
            },
            grantScreenRecording: { c.grantScreenRecording() },
            setDragging: { c.keeper.editorDragging = $0 }
        )
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: LayoutEditorWindow.defaultContentSize),
                                  styleMask: LayoutEditorWindow.styleMask, backing: .buffered, defer: false)
            LayoutEditorWindow.configure(window, model: model)
            window.setFrameAutosaveName(LayoutEditorWindow.autosaveName)
            if !window.setFrameUsingName(LayoutEditorWindow.autosaveName) { window.center() }
            window.delegate = self
            self.window = window
            observation = controller.$layoutRevision.combineLatest(controller.$settings, controller.$layoutMessage)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _, _, message in
                    MainActor.assumeIsolated {
                        guard let self, self.isVisible else { return }
                        self.model.message = message
                        self.reload()
                    }
                }
        }
        controller.layoutMessage = nil
        controller.noteVisibleApps()
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startPolling()
    }

    private func reload() {
        let content = controller.layoutEditorContent()
        model.update(rows: content.rows, images: content.images, orderAccess: content.orderAccess, pictures: content.pictures)
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                // Not while an item is dragged here (tiles must stay where the user sees them) or ⌘-dragged in the
                // menu bar (it is moving; pictures and order are read once it settles).
                guard self.model.drag == nil, !self.controller.barIsFrozen else { return }
                self.controller.captureVisibleItems { [weak self] in self?.reload() }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        model.endHover()
        if model.drag != nil {
            model.drag = nil
            controller.keeper.editorDragging = false
        }
    }
}
