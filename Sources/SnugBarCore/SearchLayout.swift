import Foundation

/// Heights of the search palette (feature 25). The panel is exactly as tall as its parts (the search field, the
/// separator, the result rows and even padding around them), so a row is never cut off. Up to `maxVisibleRows` rows
/// show; more scroll. With no results the list keeps the height of one row, for a quiet "No matches" line.
public struct SearchLayout: Equatable, Sendable {
    public var rowHeight: Double
    public var maxVisibleRows: Int
    /// Space between the separator and the first row, and between the last row and the panel's bottom edge. The
    /// selection highlight is inset by the same amount from the panel's sides.
    public var listPadding: Double

    public init(rowHeight: Double = 30, maxVisibleRows: Int = 8, listPadding: Double = 8) {
        self.rowHeight = rowHeight
        self.maxVisibleRows = maxVisibleRows
        self.listPadding = listPadding
    }

    /// Rows shown without scrolling: one per result up to the limit, and one (the "No matches" line) when empty.
    public func visibleRows(resultCount: Int) -> Int {
        min(max(resultCount, 1), max(maxVisibleRows, 1))
    }

    /// Height of the scrolling list.
    public func listHeight(resultCount: Int) -> Double {
        rowHeight * Double(visibleRows(resultCount: resultCount))
    }

    /// Whether the list has more rows than it shows.
    public func scrolls(resultCount: Int) -> Bool {
        resultCount > visibleRows(resultCount: resultCount)
    }

    /// Height of the whole panel.
    /// - Parameter header: everything above the list: top padding, the search field, the gap and the separator.
    public func panelHeight(header: Double, resultCount: Int) -> Double {
        header + listPadding + listHeight(resultCount: resultCount) + listPadding
    }
}
