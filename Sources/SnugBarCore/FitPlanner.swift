import Foundation

/// Decides which shown apps leave the menu bar so the rest fits beside the notch (features 17–18).
///
/// macOS 27 squeezes items that don't fit into its own overflow behind a « button. With "Move items that don't fit
/// into Hidden" on, SnugBar instead hides the leftmost shown apps (macOS overflows from the left too) until the
/// remaining items fit, and lists them in the SnugBar Bar under "Didn't fit". Whole apps move, because macOS 27 hides
/// per app.
public enum FitPlanner {
    /// One shown third-party app and the room its items take.
    public struct App: Codable, Equatable, Sendable {
        public var bundleID: String
        /// Sum of its items' widths, in points.
        public var width: Double
        public var itemCount: Int

        public init(bundleID: String, width: Double, itemCount: Int = 1) {
            self.bundleID = bundleID
            self.width = width
            self.itemCount = max(itemCount, 0)
        }
    }

    public struct Plan: Codable, Equatable, Sendable {
        /// Apps to take out of the menu bar, leftmost first.
        public var moved: [String]
        /// Apps that stay, left to right.
        public var kept: [String]
        /// Room available for status items.
        public var availableWidth: Double
        /// Room everything would take, including the safety margin.
        public var requiredWidth: Double
        /// Room what stays takes, including the safety margin.
        public var keptWidth: Double
        /// False when even moving every app isn't enough (or the room is unknown).
        public var fits: Bool
    }

    /// Default room kept free so a rounding difference doesn't bring back the « button.
    public static let defaultMargin = 8.0

    /// - Parameters:
    ///   - apps: shown third-party apps, left to right.
    ///   - fixedWidth: room taken by items that always stay (Apple's items, SnugBar's icon).
    ///   - fixedItemCount: how many such items there are (for spacing).
    ///   - availableWidth: room for status items (see `availableWidth(...)`).
    ///   - itemSpacing: gap between neighbouring items.
    public static func plan(
        apps: [App], fixedWidth: Double, fixedItemCount: Int, availableWidth: Double,
        itemSpacing: Double = 0, margin: Double = defaultMargin
    ) -> Plan {
        func needed(_ list: ArraySlice<App>) -> Double {
            let count = fixedItemCount + list.reduce(0) { $0 + $1.itemCount }
            let gaps = Double(max(count - 1, 0)) * max(itemSpacing, 0)
            return fixedWidth + list.reduce(0) { $0 + $1.width } + gaps + margin
        }
        let all = apps[...]
        let required = needed(all)
        guard availableWidth > 0 else {
            return Plan(moved: [], kept: apps.map(\.bundleID), availableWidth: availableWidth,
                        requiredWidth: required, keptWidth: required, fits: false)
        }
        var kept = all
        while needed(kept) > availableWidth, !kept.isEmpty {
            kept = kept.dropFirst()
        }
        let keptWidth = needed(kept)
        return Plan(
            moved: apps.prefix(apps.count - kept.count).map(\.bundleID),
            kept: kept.map(\.bundleID),
            availableWidth: availableWidth,
            requiredWidth: required,
            keptWidth: keptWidth,
            fits: keptWidth <= availableWidth
        )
    }

    /// Room for status items on one menu bar, in points.
    /// - With a notch: from the notch's right edge to the right end of the bar.
    /// - Without: from the right end of the frontmost app's menus (or the bar's left end) to the right end.
    public static func availableWidth(stripMinX: Double, stripMaxX: Double, notchMaxX: Double?, appMenusMaxX: Double?) -> Double {
        if let notchMaxX { return max(stripMaxX - notchMaxX, 0) }
        let left = max(appMenusMaxX ?? stripMinX, stripMinX)
        return max(stripMaxX - left, 0)
    }

    /// The usual gap between neighbouring items: the median of the gaps between frames that sit side by side
    /// (overlapping or far-apart frames are ignored). Zero when there is nothing to measure.
    public static func typicalGap(_ frames: [Rect]) -> Double {
        let sorted = frames.filter { $0.width > 0 }.sorted { $0.minX < $1.minX }
        var gaps: [Double] = []
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.minX - a.maxX
            if gap >= 0 && gap <= 20 { gaps.append(gap) }
        }
        guard !gaps.isEmpty else { return 0 }
        gaps.sort()
        return gaps[gaps.count / 2]
    }
}

/// Remembers how wide each app's items are, so apps SnugBar moved out of the menu bar (and so can't be measured) still
/// count when the plan is made again, e.g. after a display change.
public struct FitMeasurements: Sendable {
    public struct Measure: Codable, Equatable, Sendable {
        public var width: Double
        public var itemCount: Int
        /// Left-to-right position. Items in macOS's overflow are leftmost (macOS overflows from the left), so they get
        /// a large negative value that keeps their reported order.
        public var order: Double
    }

    public private(set) var apps: [String: Measure] = [:]

    public init() {}

    /// Records the third-party apps whose items are on screen now. Items of hidden apps can linger in the
    /// Accessibility tree with stale frames, so `isOnScreen` says which apps to trust.
    public mutating func record(_ items: [MenuBarItem], excluding: Set<String> = [], isOnScreen: (String) -> Bool) {
        var grouped: [String: [(index: Int, item: MenuBarItem)]] = [:]
        for (i, item) in items.enumerated() where !item.isAppleItem && !item.ownerBundleID.isEmpty {
            guard !excluding.contains(item.ownerBundleID), isOnScreen(item.ownerBundleID) else { continue }
            grouped[item.ownerBundleID, default: []].append((i, item))
        }
        for (bundle, entries) in grouped {
            let width = entries.reduce(0) { $0 + $1.item.frame.width }
            let overflowed = entries.first { $0.item.isOverflowed }
            let order = overflowed.map { -1_000_000 + Double($0.index) }
                ?? entries.map(\.item.frame.minX).min() ?? 0
            apps[bundle] = Measure(width: width, itemCount: entries.count, order: order)
        }
    }

    public mutating func forget(_ bundleID: String) {
        apps.removeValue(forKey: bundleID)
    }

    /// Drops every app not in `bundleIDs` (e.g. apps that quit).
    public mutating func keepOnly(_ bundleIDs: Set<String>) {
        apps = apps.filter { bundleIDs.contains($0.key) }
    }

    /// The measured apps among `bundleIDs`, left to right. Unmeasured apps are left out.
    public func ordered(_ bundleIDs: Set<String>) -> [FitPlanner.App] {
        bundleIDs.compactMap { b in apps[b].map { (b, $0) } }
            .sorted { $0.1.order != $1.1.order ? $0.1.order < $1.1.order : $0.0 < $1.0 }
            .map { FitPlanner.App(bundleID: $0.0, width: $0.1.width, itemCount: $0.1.itemCount) }
    }
}
