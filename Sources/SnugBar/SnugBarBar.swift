import AppKit
import SnugBarCore
import SnugBarEngine
import SwiftUI

/// The SnugBar Bar (features 20, 23, 24): a panel just below the menu bar, at the right near SnugBar's icon, listing
/// hidden items in groups. Clicking an item opens it; in letter mode (feature 16) typing an item's key opens it.
@MainActor
final class SnugBarBarController {
    struct Entry: Identifiable {
        let tile: BarTile
        let image: NSImage
        let key: Character?
        var id: ItemID { tile.id }
        /// What a click opens (an app tile opens the app's leftmost item).
        var item: MenuBarItem { tile.item }
    }

    struct Group: Identifiable {
        let kind: BarGroupKind
        let entries: [Entry]
        var id: BarGroupKind { kind }
    }

    final class Model: ObservableObject {
        @Published var groups: [Group] = []
        @Published var showsKeys = false
    }

    /// An item was chosen.
    var onActivate: ((MenuBarItem) -> Void)?
    /// The user closed the bar (Esc, a key with no item in letter mode, focus lost).
    var onDismiss: (() -> Void)?
    /// A click outside the bar, in global top-left coordinates. The owner decides whether it closes the bar.
    var onClickOutside: ((CGPoint) -> Void)?

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

    var isVisible: Bool { panel?.isVisible == true }
    var isShowingKeys: Bool { isVisible && model.showsKeys }

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

    /// Replaces the listed items without moving focus. Keys are kept for items that still have them.
    func update(groups: [Group]) {
        guard let panel, panel.isVisible else { return }
        model.groups = groups
        let before = panel.frame
        layout(panel)
        // Tiles may have moved; the label would point at the wrong place. It comes back when the pointer moves on.
        if panel.frame != before { endHover() }
    }

    /// Closes the bar without telling the owner (the owner asked for it).
    func dismiss() {
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
        panel.onMouseDown = { [weak self] in self?.hoverLabel.hide() }
        panel.onResignKey = { [weak self] in
            guard let self, !self.dismissing, self.isVisible else { return }
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
        let width = min(max(fitting.width, 120), maxWidth)
        let height = fitting.height
        let right = min(anchor.map { $0.maxX + 4 } ?? maxX, maxX)
        let x = max(min(right - width, maxX - width), minX)
        let top = screen.frame.maxY - screen.menuBarHeight - 4
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
    }

    // MARK: - Hover label

    private func hoverChanged(_ id: ItemID, _ hover: BarHover?) {
        if let hover {
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

    // MARK: - Input

    /// Orders the bar out before the owner focuses and clicks the item, so the bar is never drawn over its menu.
    private func choose(_ item: MenuBarItem) {
        dismiss()
        onActivate?(item)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Esc
            userDismissed()
            return true
        }
        guard model.showsKeys else { return false }
        // Shortcuts with ⌘ or ⌃ are not item keys; let them pass.
        if !event.modifierFlags.intersection([.command, .control]).isEmpty { return false }
        if let typed = event.charactersIgnoringModifiers, let id = LetterAssigner.item(for: typed, in: keys),
           let entry = model.groups.lazy.flatMap(\.entries).first(where: { $0.id == id }) {
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
                guard let self, let panel = self.panel, panel.isVisible else { return }
                if NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { return }
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
                self.userDismissed()
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

// MARK: - Views

struct BarView: View {
    @ObservedObject var model: SnugBarBarController.Model
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
                            BarItemButton(entry: entry, showsKey: model.showsKeys, onHover: onHover) { onClick(entry.item) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }
}

private struct BarItemButton: View {
    /// Every tile draws its image aspect-fit in the same box, so captured pictures and app icons line up.
    static let imageSize: CGFloat = 18
    static let tileSize: CGFloat = 24

    let entry: SnugBarBarController.Entry
    let showsKey: Bool
    let onHover: (ItemID, BarHover?) -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            image
                .frame(width: Self.imageSize, height: Self.imageSize)
                .frame(width: Self.tileSize, height: Self.tileSize)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.12) : Color.clear)
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .accessibilityLabel(entry.tile.helpText)
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
