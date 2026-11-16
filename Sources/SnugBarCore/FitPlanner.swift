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

    /// The menu bar as measured, which the estimate is built on. Status item frames from the reader already include
    /// each item's own padding: third-party items usually sit edge to edge, while Apple's keep wider gaps. So the
    /// estimate takes the fixed items' real span and the gaps actually seen, never one gap per item.
    public struct Geometry: Codable, Equatable, Sendable {
        /// From the leftmost fixed item's left edge to the rightmost one's right edge (Apple's real gaps included),
        /// less the widths of shown third-party items sitting between fixed items, which count with their apps.
        public var fixedSpan: Double
        /// Gap between neighbouring third-party items: the median of the gaps between horizontally adjacent
        /// third-party frames, 0 when there is nothing to measure.
        public var thirdPartyGap: Double
        /// Gap between the third-party items and the fixed items: measured when both are on screen, else
        /// `thirdPartyGap`.
        public var junctionGap: Double
        /// Width of the shown third-party items inside the fixed span (taken out of `fixedSpan`).
        public var insideWidth: Double

        public init(fixedSpan: Double, thirdPartyGap: Double = 0, junctionGap: Double? = nil, insideWidth: Double = 0) {
            self.fixedSpan = max(fixedSpan, 0)
            self.thirdPartyGap = max(thirdPartyGap, 0)
            self.junctionGap = max(junctionGap ?? thirdPartyGap, 0)
            self.insideWidth = max(insideWidth, 0)
        }

        /// Gaps wider than this aren't spacing between neighbours (something else sits there, or the items are apart).
        static let maxGap = 20.0

        /// Measures on-screen frames.
        /// - Parameters:
        ///   - fixed: items that always stay (Apple's items, SnugBar's own icon and spacers).
        ///   - thirdParty: on-screen items of the shown third-party apps being planned.
        public static func measure(fixed: [Rect], thirdParty: [Rect]) -> Geometry {
            let fixed = fixed.filter { $0.width > 0 }
            let thirdParty = thirdParty.filter { $0.width > 0 }
            // Third-party pairs that are neighbours in the bar (nothing fixed between them).
            let all = (fixed.map { ($0, true) } + thirdParty.map { ($0, false) }).sorted { $0.0.minX < $1.0.minX }
            var gaps: [Double] = []
            for (a, b) in zip(all, all.dropFirst()) where !a.1 && !b.1 {
                let gap = b.0.minX - a.0.maxX
                if gap >= 0, gap <= maxGap { gaps.append(gap) }
            }
            let thirdPartyGap = median(gaps) ?? 0
            guard let minX = fixed.map(\.minX).min(), let maxX = fixed.map(\.maxX).max() else {
                return Geometry(fixedSpan: 0, thirdPartyGap: thirdPartyGap)
            }
            let inside = thirdParty.filter { $0.midX > minX && $0.midX < maxX }
            let insideWidth = inside.reduce(0) { $0 + $1.width }
            var junction: Double?
            if let left = thirdParty.filter({ $0.midX <= minX }).max(by: { $0.maxX < $1.maxX }) {
                let gap = minX - left.maxX
                if gap >= 0, gap <= maxGap { junction = gap }
            }
            return Geometry(fixedSpan: maxX - minX - insideWidth, thirdPartyGap: thirdPartyGap, junctionGap: junction,
                            insideWidth: insideWidth)
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
        /// Apps already out that would just fit but stay out, because they don't fit with `returnMargin` to spare.
        public var heldBack: [String] = []
    }

    /// Default room kept free so a rounding difference doesn't bring back the « button.
    public static let defaultMargin = 8.0
    /// Extra room an app already moved out needs before it comes back, so an app near the edge isn't moved out and
    /// back in again on every check.
    public static let defaultReturnMargin = 8.0

    /// - Parameters:
    ///   - apps: shown third-party apps, left to right, with their remembered widths (also for apps that are off
    ///     screen now).
    ///   - geometry: the measured fixed span and gaps (`Geometry.measure`).
    ///   - availableWidth: room for status items (see `availableWidth(...)`).
    ///   - movedNow: apps out of the menu bar for room now; they come back only with `returnMargin` to spare.
    public static func plan(
        apps: [App], geometry: Geometry, availableWidth: Double, margin: Double = defaultMargin,
        movedNow: Set<String> = [], returnMargin: Double = defaultReturnMargin
    ) -> Plan {
        func needed(_ list: ArraySlice<App>) -> Double {
            let items = list.reduce(0) { $0 + max($1.itemCount, 1) }
            let gaps = items > 0 ? geometry.junctionGap + Double(items - 1) * geometry.thirdPartyGap : 0
            return geometry.fixedSpan + list.reduce(0) { $0 + $1.width } + gaps + margin
        }
        func keep(extra: Double) -> ArraySlice<App> {
            var kept = apps[...]
            while !kept.isEmpty {
                let returning = kept.contains { movedNow.contains($0.bundleID) }
                if needed(kept) + (returning ? extra : 0) <= availableWidth { break }
                kept = kept.dropFirst()
            }
            return kept
        }
        let required = needed(apps[...])
        guard availableWidth > 0 else {
            return Plan(moved: [], kept: apps.map(\.bundleID), availableWidth: availableWidth,
                        requiredWidth: required, keptWidth: required, fits: false)
        }
        let kept = keep(extra: max(returnMargin, 0))
        let keptWidth = needed(kept)
        let moved = apps.prefix(apps.count - kept.count).map(\.bundleID)
        let movedWithoutHold = Set(apps.prefix(apps.count - keep(extra: 0).count).map(\.bundleID))
        return Plan(
            moved: moved,
            kept: kept.map(\.bundleID),
            availableWidth: availableWidth,
            requiredWidth: required,
            keptWidth: keptWidth,
            fits: keptWidth <= availableWidth,
            heldBack: moved.filter { !movedWithoutHold.contains($0) }
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
            if gap >= 0 && gap <= Geometry.maxGap { gaps.append(gap) }
        }
        return median(gaps) ?? 0
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
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
            let order = overflowed.map { Self.overflowOrder + Double($0.index) }
                ?? entries.map(\.item.frame.minX).min() ?? 0
            apps[bundle] = Measure(width: width, itemCount: entries.count, order: order)
        }
    }

    /// Order given to apps that are off the bar (in macOS's overflow, or missing from the tree): left of everything on
    /// screen, as macOS overflows from the left.
    static let overflowOrder = -1_000_000.0
    static let offBarOrder = -2_000_000.0

    /// Measures apps among `bundleIDs` that were never measured collapsed from items remembered from another time
    /// they were on screen (e.g. while revealed, or focused to open one). Their order is unknown, so they count as off
    /// the bar (leftmost), keeping their remembered left-to-right order.
    public mutating func adopt(_ remembered: [String: [MenuBarItem]], for bundleIDs: Set<String>) {
        for bundle in bundleIDs where apps[bundle] == nil {
            let items = (remembered[bundle] ?? []).filter { !$0.isAppleItem && $0.frame.width > 0 }
            guard !items.isEmpty else { continue }
            let width = items.reduce(0) { $0 + $1.frame.width }
            let left = items.map(\.frame.minX).min() ?? 0
            apps[bundle] = Measure(width: width, itemCount: items.count, order: Self.offBarOrder + left)
        }
    }

    /// Apps let through but with no item in the bar's tree now: macOS keeps them off the bar, so they are leftmost
    /// (and so the first to move out), keeping their relative order.
    public mutating func markOffBar(_ bundleIDs: Set<String>) {
        for bundle in bundleIDs {
            // Only apps last measured on screen; ones measured in the overflow are leftmost already.
            guard var m = apps[bundle], m.order > Self.overflowOrder / 2 else { continue }
            m.order += Self.offBarOrder
            apps[bundle] = m
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
