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

    private var panel: OverlayPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matching items")
    private var heightConstraint: NSLayoutConstraint?
    private var items: [MenuBarItem] = []
    private var recents: [ItemID] = []
    private var results: [FuzzyMatcher.Result] = []
    private var closing = false

    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 30
    static let visibleRows = 8

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let panel = self.panel ?? makePanel()
        let s = source?() ?? Source(items: [], recents: [])
        items = s.items
        recents = s.recents
        field.stringValue = ""
        refresh()
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(field)
    }

    func dismiss() {
        closing = true
        panel?.orderOut(nil)
        closing = false
    }

    // MARK: - Building

    private func makePanel() -> OverlayPanel {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        panel.onResignKey = { [weak self] in
            guard let self, !self.closing, self.isVisible else { return }
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

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .inset
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

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let separator = NSBox()
        separator.boxType = .separator

        let content = NSView()
        for v in [icon, field, separator, scroll, emptyLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let height = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * CGFloat(Self.visibleRows))
        heightConstraint = height
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: Self.width),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            height,
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        panel.setMaterialContent(content, cornerRadius: 14)
        self.panel = panel
        return panel
    }

    private func position(_ panel: OverlayPanel) {
        let screen = NSScreen.containing(NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let x = screen.visibleFrame.midX - size.width / 2
        let top = screen.visibleFrame.maxY - screen.visibleFrame.height * 0.2
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// Resizes the list to its rows, keeping the panel's top edge in place.
    private func fitHeight() {
        guard let panel, let content = panel.contentView else { return }
        let rows = min(max(results.count, 1), Self.visibleRows)
        heightConstraint?.constant = Self.rowHeight * CGFloat(rows) + (results.isEmpty ? 8 : 0)
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    // MARK: - Results

    private func refresh() {
        results = FuzzyMatcher.rank(field.stringValue, items: items, recents: recents)
        table.reloadData()
        emptyLabel.isHidden = !results.isEmpty
        emptyLabel.stringValue = items.isEmpty ? "No menu bar items found" : "No matching items"
        if !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        if panel?.isVisible == true { fitHeight() } else { heightConstraint?.constant = Self.rowHeight * CGFloat(min(max(results.count, 1), Self.visibleRows)) }
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

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("SearchRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SearchRowView) ?? SearchRowView(identifier: id)
        let item = results[row].item
        cell.configure(title: item.displayName, detail: detail?(item) ?? "", image: image?(item))
        return cell
    }
}

/// One search result: image, name, and where the item lives.
private final class SearchRowView: NSTableCellView {
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
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
