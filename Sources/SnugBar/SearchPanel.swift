import AppKit
import SnugBarCore

/// The search palette (features 25–28): a field and a list of menu bar items, ranked by `FuzzyMatcher`.
/// ↑ ↓ move the selection, Return opens the selected item, Esc closes.
@MainActor
final class SearchPanelController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Source {
        var items: [MenuBarItem]
        var recents: [ItemID]
    }

    /// Items to search and the recent list, read each time the palette opens.
    var source: (() -> Source)?
    /// Secondary text for a row (where the item lives).
    var detail: ((MenuBarItem) -> String)?
    var image: ((MenuBarItem) -> NSImage)?
    var onActivate: ((MenuBarItem) -> Void)?
    /// SnugBar's icon, in AppKit screen coordinates (see `takeIconPressDismissal`).
    var ownIconFrame: (() -> NSRect?)?

    private var panel: OverlayPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matches")
    private var listHeightConstraint: NSLayoutConstraint?
    private var items: [MenuBarItem] = []
    private var recents: [ItemID] = []
    private var results: [FuzzyMatcher.Result] = []
    private var closing = false
    /// The panel's top edge (AppKit screen coordinates) while it is open: it grows and shrinks downward from here.
    private var topEdge: CGFloat?
    /// When the palette last closed because SnugBar's icon was pressed.
    private var iconPressDismissal: Date?

    static let width: CGFloat = 560
    static let layout = SearchLayout(rowHeight: 30, maxVisibleRows: 8, listPadding: 8)
    /// Above the field, and between the field and the separator.
    static let fieldTop: CGFloat = 14
    static let fieldBottom: CGFloat = 12
    /// Leading and trailing space of the search icon and field; result icons line up with the search icon.
    static let sideInset: CGFloat = 16

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let panel = self.panel ?? makePanel()
        let s = source?() ?? Source(items: [], recents: [])
        items = s.items
        recents = s.recents
        iconPressDismissal = nil
        field.stringValue = ""
        let screen = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            topEdge = screen.visibleFrame.maxY - screen.visibleFrame.height * 0.2
            panel.setFrameOrigin(NSPoint(x: (screen.visibleFrame.midX - Self.width / 2).rounded(), y: panel.frame.minY))
        }
        refresh()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
    }

    func dismiss() {
        closing = true
        panel?.orderOut(nil)
        closing = false
    }

    /// True (once) when the palette has just closed because SnugBar's icon was pressed: that click only closes
    /// search. Pressing the icon takes focus from the palette, which closes it before the icon's action runs.
    func takeIconPressDismissal() -> Bool {
        defer { iconPressDismissal = nil }
        guard let when = iconPressDismissal else { return false }
        return Date().timeIntervalSince(when) < 1.5
    }

    // MARK: - Building

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        panel.onResignKey = { [weak self] in
            guard let self, !self.closing, self.isVisible else { return }
            if NSEvent.isPressingOnOwnIcon(self.ownIconFrame?()) { self.iconPressDismissal = Date() }
            self.dismiss()
        }
        panel.keyHandler = { [weak self] event in
            guard let self else { return false }
            if event.keyCode == 53 { self.dismiss(); return true } // Esc, wherever focus is
            return false
        }

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        field.placeholderString = "Search menu bar items"
        field.font = .systemFont(ofSize: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true

        // Plain style: the table adds no padding of its own (the inset style pads above the first row, which the
        // panel's height didn't count, cutting the last row off). The rounded selection is drawn by `SearchRowBackground`.
        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = CGFloat(Self.layout.rowHeight)
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.lineBreakMode = .byTruncatingTail

        let separator = NSBox()
        separator.boxType = .separator

        let content = NSView()
        for v in [icon, field, separator, scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let layout = Self.layout
        let listHeight = scroll.heightAnchor.constraint(equalToConstant: CGFloat(layout.listHeight(resultCount: 0)))
        listHeightConstraint = listHeight
        // The panel's frame is set to the computed height; the bottom gives way by a fraction rather than conflict.
        let bottom = scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -CGFloat(layout.listPadding))
        bottom.priority = .init(999)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.sideInset),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: SearchRowView.iconSize),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.sideInset),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.fieldTop),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Self.fieldBottom),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: CGFloat(layout.listPadding)),
            bottom,
            listHeight,
            // "No matches" sits where a row's title would be.
            emptyLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: SearchRowView.titleLeading),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -Self.sideInset),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.topAnchor, constant: CGFloat(layout.rowHeight) / 2),
        ])
        panel.setMaterialContent(content, cornerRadius: 14)
        self.panel = panel
        return panel
    }

    /// Everything above the list: top padding, the field, the gap and the separator.
    private var headerHeight: CGFloat {
        Self.fieldTop + ceil(field.intrinsicContentSize.height) + Self.fieldBottom + 1
    }

    /// Sizes the panel to the field, the separator and the current rows, keeping its top edge in place.
    private func fitHeight() {
        guard let panel else { return }
        let layout = Self.layout
        listHeightConstraint?.constant = CGFloat(layout.listHeight(resultCount: results.count))
        let height = CGFloat(layout.panelHeight(header: Double(headerHeight), resultCount: results.count))
        let top = topEdge ?? panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: Self.width, height: height), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    // MARK: - Results

    private func refresh() {
        results = FuzzyMatcher.rank(field.stringValue, items: items, recents: recents)
        table.reloadData()
        emptyLabel.isHidden = !results.isEmpty
        emptyLabel.stringValue = items.isEmpty ? "No menu bar items" : "No matches"
        fitHeight()
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = table.selectedRow
        let next = min(max((current < 0 ? -1 : current) + delta, 0), results.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func activateSelection() {
        let row = table.selectedRow
        guard row >= 0, row < results.count else { NSSound.beep(); return }
        let item = results[row].item
        dismiss()
        onActivate?(item)
    }

    @objc private func rowClicked() {
        // Single click selects; keep typing focus in the field.
        panel?.makeFirstResponder(field)
    }

    @objc private func rowDoubleClicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        activateSelection()
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): activateSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("SearchRowBackground")
        return (tableView.makeView(withIdentifier: id, owner: nil) as? SearchRowBackground) ?? {
            let view = SearchRowBackground()
            view.identifier = id
            return view
        }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SearchRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SearchRowView) ?? SearchRowView(identifier: id)
        let item = results[row].item
        cell.configure(title: item.displayName, detail: detail?(item) ?? "", image: image?(item))
        return cell
    }
}

/// A result row's background: the selection is a rounded rectangle inset from the panel's sides by the list's
/// padding, so it sits fully inside the panel with the same space on every side.
private final class SearchRowBackground: NSTableRowView {
    static let cornerRadius: CGFloat = 6

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let inset = CGFloat(SearchPanelController.layout.listPadding)
        let rect = bounds.insetBy(dx: inset, dy: 0)
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }
}

/// One search result: image, name, and where the item lives.
private final class SearchRowView: NSTableCellView {
    static let iconSize: CGFloat = 18
    /// From the row's (and the panel's) leading edge: the icon lines up with the search icon, the title with the
    /// search text.
    static let iconLeading = SearchPanelController.sideInset
    static let titleLeading = iconLeading + iconSize + 10

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        // Same box for captured pictures and app icons; template pictures take the label colour.
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [icon, title, detail] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconLeading),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.titleLeading),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SearchPanelController.sideInset),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(title text: String, detail info: String, image: NSImage?) {
        title.stringValue = text
        detail.stringValue = info
        icon.image = image
    }
}
