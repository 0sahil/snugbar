import AppKit
import SnugBarCore
import SnugBarEngine
import SwiftUI

/// The SnugBar Bar (features 20, 23, 24): a panel just below the menu bar, at the right near SnugBar's icon, listing
/// hidden items in groups. Clicking an item opens it; in letter mode (feature 16) typing an item's key opens it.
/// With Menu Bar folder access, a tile can be dragged to reorder its group or onto the other group to move its app.
@MainActor
final class SnugBarBarController {
    struct Entry: Identifiable {
        let tile: BarTile
        let image: NSImage
        let key: Character?
        /// The tile can be dragged (`BarDrag.canDrag`).
        var canDrag = false
        var id: ItemID { tile.id }
        /// What a click opens (an app tile opens the app's leftmost item).
        var item: MenuBarItem { tile.item }
    }

    struct Group: Identifiable {
        let kind: BarGroupKind
        let entries: [Entry]
        /// The section the group orders, nil when it can't be ordered from the bar (`BarDrag.section(of:swapped:)`).
        var section: SnugBarCore.Section?
        var id: BarGroupKind { kind }
    }

    /// A tile dropped on a group, for the owner to turn into a `BarDrag.Outcome` and apply.
    struct DropRequest {
        let tile: BarTile
        let from: SnugBarCore.Section?
        let onto: SnugBarCore.Section?
        /// Insertion index in `row`.
        let gap: Int
        /// The target group's tiles, the dragged one included when it is the same group.
        let row: [BarTile]
    }

    struct DragState {
        let id: ItemID
        let from: BarGroupKind
        /// The pointer, in the bar's coordinates (top-left origin).
        var location: CGPoint
        /// Where the tile was grabbed, from its top-left corner; the tile follows the pointer with this offset.
        let grab: CGSize
        var target: BarGroupKind?
        var gap: Int?
    }

    final class Model: ObservableObject {
        @Published var groups: [Group] = []
        @Published var showsKeys = false
        @Published var drag: DragState?
        /// Tile and group frames in `BarView.coordinateSpace`; updated by layout, not published (no redraw loop).
        var tileFrames: [ItemID: CGRect] = [:]
        var groupFrames: [BarGroupKind: CGRect] = [:]

        func entry(_ id: ItemID) -> Entry? {
            groups.lazy.flatMap(\.entries).first { $0.id == id }
        }

        func group(containing id: ItemID) -> Group? {
            groups.first { $0.entries.contains { $0.id == id } }
        }

        /// The tile under a point.
        func tile(at point: CGPoint) -> ItemID? {
            groups.lazy.flatMap(\.entries).first { self.tileFrames[$0.id]?.contains(point) == true }?.id
        }

        private func frames(of group: Group) -> [Rect] {
            group.entries.map { Rect(tileFrames[$0.id] ?? .zero) }
        }

        func beginDrag(_ id: ItemID, at point: CGPoint) {
            guard let group = group(containing: id), group.entries.first(where: { $0.id == id })?.canDrag == true,
                  let frame = tileFrames[id] else { return }
            drag = DragState(id: id, from: group.kind, location: point,
                             grab: CGSize(width: point.x - frame.minX, height: point.y - frame.minY))
            moveDrag(to: point)
        }

        func moveDrag(to point: CGPoint) {
            guard var state = drag else { return }
            state.location = point
            // Frames of groups no longer listed are left out.
            let listed = Set(groups.map(\.kind))
            let target = BarDrag.group(atX: point.x, y: point.y, frames: groupFrames.filter { listed.contains($0.key) }.mapValues(Rect.init))
            // Only groups that are sections take a drop (not "Didn't fit").
            if let target, let group = groups.first(where: { $0.kind == target }), group.section != nil {
                state.target = target
                state.gap = BarDrag.dropIndex(frames: frames(of: group), x: point.x, y: point.y)
            } else {
                state.target = nil
                state.gap = nil
            }
            drag = state
        }

        /// What the current drag would drop, or nil when it is away from every group that takes a drop.
        func dropRequest() -> DropRequest? {
            guard let state = drag, let targetKind = state.target, let gap = state.gap,
                  let target = groups.first(where: { $0.kind == targetKind }),
                  let source = groups.first(where: { $0.kind == state.from }),
                  let entry = source.entries.first(where: { $0.id == state.id })
            else { return nil }
            return DropRequest(tile: entry.tile, from: source.section, onto: target.section, gap: gap, row: target.entries.map(\.tile))
        }

        /// The insertion marker for the current drag, in the bar's coordinates.
        var insertionMarker: CGRect? {
            guard let state = drag, let targetKind = state.target, let gap = state.gap,
                  let target = groups.first(where: { $0.kind == targetKind })
            else { return nil }
            if target.entries.isEmpty { return nil }
            return BarDrag.insertionMarker(frames: frames(of: target), gap: gap, y: state.location.y).map(CGRect.init)
        }
    }

    /// An item was chosen.
    var onActivate: ((MenuBarItem) -> Void)?
    /// The user closed the bar (Esc, a key with no item in letter mode, focus lost).
    var onDismiss: (() -> Void)?
    /// A click outside the bar, in global top-left coordinates. The owner decides whether it closes the bar.
    var onClickOutside: ((CGPoint) -> Void)?
    /// SnugBar's icon, in AppKit screen coordinates. A press on it is not a click outside the bar and doesn't close
    /// it on focus loss either: the icon's action (on mouse-up) closes the bar. Otherwise the mouse-down closed it
    /// and the action opened it again.
    var ownIconFrame: (() -> NSRect?)?
    /// A tile was dropped. The owner applies it and refreshes the rows (`update(groups:)`).
    var onDrop: ((DropRequest) -> Void)?
    /// A drag in the bar started (true) or ended (false).
    var onDragging: ((Bool) -> Void)?

    private let model = Model()
    private var panel: OverlayPanel?
    private var hosting: NSHostingController<BarView>?
    private var dismissing = false
    private var monitors: [Any] = []
    private var keys: [ItemID: Character] = [:]
    private var anchor: NSRect?
    private let hoverLabel = HoverLabel()
    /// The tile under the pointer, so a late exit from a tile the pointer already left doesn't hide the next label.
    private var hoveredID: ItemID?
    /// The left button went down on this tile and is still down.
    private var press: (id: ItemID, state: BarPress)?
    /// Rows that arrived during a drag; shown when it ends, so tiles stay where the user sees them meanwhile.
    private var pendingGroups: [Group]?

    var isVisible: Bool { panel?.isVisible == true }
    var isShowingKeys: Bool { isVisible && model.showsKeys }
    /// A tile is being dragged in the bar.
    var isDragging: Bool { model.drag != nil }

    /// True when the pointer is over the bar.
    var containsPointer: Bool {
        guard let panel, panel.isVisible else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
    }

    /// Shows (or refreshes) the bar.
    /// - Parameters:
    ///   - anchor: SnugBar's icon in AppKit screen coordinates; the bar aligns its right edge with it.
    ///   - focus: take keyboard focus (needed for letter mode; lets Esc close the bar without reaching other apps).
    func show(groups: [Group], keys: [ItemID: Character], anchor: NSRect?, focus: Bool) {
        let panel = self.panel ?? makePanel()
        pendingGroups = nil
        endDrag()
        self.keys = keys
        self.anchor = anchor
        model.showsKeys = !keys.isEmpty
        model.groups = groups
        layout(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            installMonitors()
        }
        if focus { panel.makeKey() }
    }

    /// Replaces the listed items without moving focus. Keys are kept for items that still have them. During a drag
    /// the rows wait until it ends.
    func update(groups: [Group]) {
        guard let panel, panel.isVisible else { return }
        if isDragging {
            pendingGroups = groups
            return
        }
        pendingGroups = nil
        model.groups = groups
        let before = panel.frame
        layout(panel)
        // Tiles may have moved; the label would point at the wrong place. It comes back when the pointer moves on.
        if panel.frame != before { endHover() }
    }

    /// Closes the bar without telling the owner (the owner asked for it).
    func dismiss() {
        press = nil
        pendingGroups = nil
        endDrag()
        endHover()
        removeMonitors()
        keys = [:]
        model.showsKeys = false
        dismissing = true
        panel?.orderOut(nil)
        dismissing = false
    }

    // MARK: - Panel

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel()
        let controller = NSHostingController(rootView: BarView(
            model: model,
            onClick: { [weak self] item in self?.choose(item) },
            onHover: { [weak self] id, hover in self?.hoverChanged(id, hover) }
        ))
        controller.sizingOptions = [] // the panel is sized by `layout`, not by SwiftUI
        hosting = controller
        panel.setMaterialContent(controller.view)
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.mouseHandler = { [weak self] event in self?.handleMouse(event) ?? false }
        panel.onMouseDown = { [weak self] in self?.hoverLabel.hide() }
        panel.onResignKey = { [weak self] in
            guard let self, !self.dismissing, self.isVisible, !self.isDragging else { return }
            // A press on SnugBar's icon: its action closes the bar.
            if NSEvent.isPressingOnOwnIcon(self.ownIconFrame?()) { return }
            // Focus went elsewhere (another window or app): the bar is done.
            self.userDismissed()
        }
        self.panel = panel
        return panel
    }

    private func layout(_ panel: OverlayPanel) {
        guard let hosting else { return }
        let screen = anchor.flatMap { NSScreen.containing(NSPoint(x: $0.midX, y: $0.midY)) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let margin: CGFloat = 6
        // Keep clear of the notch: on a notched screen the bar stays in the area right of it.
        var minX = screen.frame.minX + margin
        if let right = screen.auxiliaryTopRightArea { minX = max(minX, right.minX + margin) }
        let maxX = screen.frame.maxX - margin
        let maxWidth = max(maxX - minX, 160)
        let fitting = hosting.sizeThatFits(in: NSSize(width: maxWidth, height: 10_000))
        let width = min(max(fitting.width, BarView.minWidth), maxWidth)
        let height = fitting.height
        let right = min(anchor.map { $0.maxX + 4 } ?? maxX, maxX)
        let x = max(min(right - width, maxX - width), minX)
        let top = screen.frame.maxY - screen.menuBarHeight - 4
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    // MARK: - Hover label

    private func hoverChanged(_ id: ItemID, _ hover: BarHover?) {
        if let hover {
            guard !isDragging else { return }
            hoveredID = id
            hoverLabel.pointerEntered(text: hover.text, tileRect: hover.rect, parent: hover.window)
        } else if hoveredID == id {
            hoveredID = nil
            hoverLabel.pointerExited()
        }
    }

    private func endHover() {
        hoveredID = nil
        hoverLabel.hide()
    }

    // MARK: - Click and drag

    /// An event's location in the bar's coordinates (top-left origin, as `BarView.coordinateSpace`).
    private func barPoint(_ event: NSEvent) -> CGPoint? {
        guard let view = hosting?.view else { return nil }
        let p = view.convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: view.isFlipped ? p.y : view.bounds.height - p.y)
    }

    /// Tiles open on mouse-up unless the press became a drag (`BarPress`): a press that moves less than the threshold
    /// is always a click.
    private func handleMouse(_ event: NSEvent) -> Bool {
        guard let point = barPoint(event) else { return false }
        switch event.type {
        case .leftMouseDown:
            press = nil
            guard let id = model.tile(at: point) else { return false }
            // Letter mode is a keyboard flow; it keeps tiles still.
            let canDrag = !model.showsKeys && model.entry(id)?.canDrag == true
            press = (id, BarPress(x: point.x, y: point.y, canDrag: canDrag))
            // The panel still sees the press (it takes focus as before); tiles have no button of their own.
            return false
        case .leftMouseDragged:
            guard var current = press else { return false }
            if current.state.moved(toX: point.x, y: point.y) {
                endHover()
                model.beginDrag(current.id, at: point)
                if isDragging { onDragging?(true) }
            }
            press = current
            if current.state.isDragging { model.moveDrag(to: point) }
            return true
        case .leftMouseUp:
            guard let current = press else { return false }
            press = nil
            let inside = model.tile(at: point) == current.id
            switch current.state.released(atX: point.x, y: point.y, insideTile: inside) {
            case .click:
                if let entry = model.entry(current.id) { choose(entry.item) }
            case .drop:
                drop(at: point)
            case .nothing:
                break
            }
            return true
        default:
            return false
        }
    }

    private func drop(at point: CGPoint) {
        model.moveDrag(to: point)
        let request = model.dropRequest()
        endDrag()
        if let request { onDrop?(request) }
    }

    /// Esc during a drag: the tile goes back and the button's release does nothing.
    private func cancelDrag() {
        press?.state.cancel()
        endDrag()
    }

    /// Ends a drag without dropping and shows rows that arrived meanwhile.
    private func endDrag() {
        guard isDragging else { return }
        model.drag = nil
        onDragging?(false)
        if let pending = pendingGroups { update(groups: pending) }
    }

    // MARK: - Input

    /// Orders the bar out before the owner focuses and clicks the item, so the bar is never drawn over its menu.
    private func choose(_ item: MenuBarItem) {
        dismiss()
        onActivate?(item)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Esc
            if isDragging { cancelDrag() } else { userDismissed() }
            return true
        }
        guard model.showsKeys else { return false }
        // Shortcuts with ⌘ or ⌃ are not item keys; let them pass.
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        if let typed = event.charactersIgnoringModifiers, let id = LetterAssigner.item(for: typed, in: keys),
           let entry = model.entry(id) {
            choose(entry.item)
        } else {
            userDismissed()
        }
        return true
    }

    private func userDismissed() {
        dismiss()
        onDismiss?()
    }

    private func installMonitors() {
        removeMonitors()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            let location = event.cgEvent?.location
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible, !self.isDragging else { return }
                guard MenuBarGeometry.isClickOutside(NSEvent.mouseLocation, panel: panel.frame, ownIcon: self.ownIconFrame?())
                else { return }
                if let location { self.onClickOutside?(location) }
            }
        }) {
            monitors.append(m)
        }
        // Esc while the bar doesn't have focus (opened by hovering or scrolling). The key still reaches the frontmost app.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let code = event.keyCode
            MainActor.assumeIsolated {
                guard let self, code == 53, self.isVisible, self.panel?.isKeyWindow != true else { return }
                if self.isDragging { self.cancelDrag() } else { self.userDismissed() }
            }
        }) {
            monitors.append(m)
        }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }
}

extension Rect {
    init(_ r: CGRect) {
        self.init(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }
}

extension CGRect {
    init(_ r: Rect) {
        self.init(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}

// MARK: - Views

struct BarView: View {
    static let coordinateSpace = "snugbar-bar"
    /// The bar is never narrower than this; the content fills it from the left, so its coordinates match the panel's.
    static let minWidth: CGFloat = 120

    @ObservedObject var model: SnugBarBarController.Model
    /// Accessibility's press action (pointer clicks are handled by the controller, to tell them from drags).
    let onClick: (MenuBarItem) -> Void
    /// The pointer entered (with the label to show) or left (nil) a tile.
    let onHover: (ItemID, BarHover?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.groups.isEmpty {
                Text("No hidden items")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
            }
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.kind.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    FlowLayout(spacing: 2, lineSpacing: 2) {
                        ForEach(group.entries) { entry in
                            BarItemButton(
                                entry: entry, showsKey: model.showsKeys, isDragging: model.drag != nil,
                                isDragged: model.drag?.id == entry.id, onHover: onHover
                            ) { onClick(entry.item) }
                        }
                    }
                }
                .background(FrameReporter { model.groupFrames[group.kind] = $0 })
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .frame(minWidth: Self.minWidth, alignment: .topLeading)
        .overlay(alignment: .topLeading) { dragOverlay }
        .coordinateSpace(name: Self.coordinateSpace)
        .onPreferenceChange(BarTileFrameKey.self) { frames in MainActor.assumeIsolated { model.tileFrames = frames } }
    }

    /// The dragged tile under the pointer, and the insertion marker above it (so the tile never hides it).
    @ViewBuilder private var dragOverlay: some View {
        if let drag = model.drag, let entry = model.entry(drag.id) {
            BarTileContent(entry: entry)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.12)))
                .opacity(0.85)
                .offset(x: drag.location.x - drag.grab.width, y: drag.location.y - drag.grab.height)
                .allowsHitTesting(false)
        }
        if let line = model.insertionMarker {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.accentColor)
                .frame(width: line.width, height: line.height)
                .offset(x: line.minX, y: line.minY)
                .allowsHitTesting(false)
        }
    }
}

/// A tile's picture in its box: the same for the tile and for the copy under the pointer while dragging.
private struct BarTileContent: View {
    /// Every tile draws its image aspect-fit in the same box, so captured pictures and app icons line up.
    static let imageSize: CGFloat = 18
    static let tileSize: CGFloat = 24

    let entry: SnugBarBarController.Entry

    var body: some View {
        image
            .frame(width: Self.imageSize, height: Self.imageSize)
            .frame(width: Self.tileSize, height: Self.tileSize)
            .padding(.horizontal, 3)
    }

    /// Template pictures (keyed captures) take the label colour; app icons keep theirs.
    @ViewBuilder private var image: some View {
        if entry.image.isTemplate {
            Image(nsImage: entry.image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
        } else {
            Image(nsImage: entry.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        }
    }
}

private struct BarItemButton: View {
    let entry: SnugBarBarController.Entry
    let showsKey: Bool
    /// Some tile is being dragged: no hover highlight while the pointer passes over others.
    let isDragging: Bool
    /// This tile is the one dragged: it stays in place, dimmed.
    let isDragged: Bool
    let onHover: (ItemID, BarHover?) -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        BarTileContent(entry: entry)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering && !isDragging ? Color.primary.opacity(0.12) : Color.clear)
            )
            .overlay(alignment: .bottomTrailing) {
                if showsKey, let key = entry.key {
                    Text(String(key).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .frame(minWidth: 14, minHeight: 14)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor))
                        )
                }
            }
            .opacity(isDragged ? 0.35 : 1)
            .contentShape(Rectangle())
            .background(GeometryReader { geo in
                Color.clear.preference(key: BarTileFrameKey.self, value: [entry.id: geo.frame(in: .named(BarView.coordinateSpace))])
            })
            .onHover { hovering = $0 }
            // SwiftUI hover and `.help` only track in the active app; this tracks always and drives the bar's own label.
            .background(HoverTracker(
                onEnter: { rect, window in
                    hovering = true
                    onHover(entry.id, BarHover(text: entry.tile.helpText, rect: rect, window: window))
                },
                onExit: {
                    hovering = false
                    onHover(entry.id, nil)
                }
            ))
            .help(entry.tile.helpText)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(entry.tile.helpText)
            .accessibilityAction { action() }
    }
}

private struct BarTileFrameKey: PreferenceKey {
    static let defaultValue: [ItemID: CGRect] = [:]
    static func reduce(value: inout [ItemID: CGRect], nextValue: () -> [ItemID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Reports a view's frame in the bar's coordinates whenever it changes (not published, so no redraw loop).
private struct FrameReporter: View {
    let report: (CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(BarView.coordinateSpace))
            Color.clear
                .onAppear { report(frame) }
                .onChange(of: frame) { _, new in report(new) }
        }
    }
}

/// Lays out views left to right, wrapping to a new line when the width runs out. Lines are centred vertically.
struct FlowLayout: Layout {
    var spacing: CGFloat = 2
    var lineSpacing: CGFloat = 2

    private struct Line { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func lines(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let extra = lines[lines.count - 1].indices.isEmpty ? size.width : spacing + size.width
            if !lines[lines.count - 1].indices.isEmpty, lines[lines.count - 1].width + extra > maxWidth {
                lines.append(Line())
            }
            let last = lines.count - 1
            lines[last].width += lines[last].indices.isEmpty ? size.width : spacing + size.width
            lines[last].height = max(lines[last].height, size.height)
            lines[last].indices.append(i)
        }
        return lines.filter { !$0.indices.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let all = lines(for: subviews, maxWidth: proposal.width ?? .infinity)
        let width = all.map(\.width).max() ?? 0
        let height = all.reduce(0) { $0 + $1.height } + CGFloat(max(all.count - 1, 0)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for i in line.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + line.height / 2), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}
