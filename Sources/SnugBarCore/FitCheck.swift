import Foundation

/// What the fit check reads off the collapsed menu bar: which items really sit on screen (and so may be measured),
/// which were left out and why, and whether macOS's own overflow shows (the sign that something didn't fit).
///
/// Only items really on screen count for the span and the gaps: not in macOS's overflow, not behind the notch, with a
/// width, of an app SnugBar lets through, and not overlapping a neighbour. Items in the overflow are stacked on top of
/// each other under the « button, and items of hidden apps (or of an app partly in the overflow) can keep a stale
/// frame that overlaps real items; measuring those gave bogus gaps.
public struct FitSurvey: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// In macOS's overflow (its frame is stacked under the « button).
        case overflowed
        /// Behind the camera housing: not visible, whatever the overflow flag says.
        case behindNotch
        case noWidth
        /// Its app is hidden by SnugBar now: a stale frame.
        case notAllowed
        /// Not one of the shown apps being planned (moved out for room now, or never measured).
        case notPlanned
        /// Another item of its app is in the overflow: macOS hasn't drawn this one where its frame says.
        case appOverflowed
        /// Overlaps a neighbour by more than a point: one of the two frames is stale.
        case overlaps
        /// No owner app: can't be counted with an app.
        case unknownOwner
    }

    public struct Ignored: Codable, Equatable, Sendable {
        public var id: String
        public var bundleID: String
        public var x: Double
        public var width: Double
        public var reason: Reason
    }

    public var geometry: FitPlanner.Geometry
    /// Fixed items (Apple's and SnugBar's own) measured: their widths added up, and how many.
    public var fixedWidth: Double
    public var fixedItemCount: Int
    /// The usual gap between Apple's items (information only).
    public var appleGap: Double
    /// Items left out of the measurement, left to right.
    public var ignored: [Ignored]
    /// Shown apps with an item in macOS's overflow or behind the notch now.
    public var overflowedApps: [String]
    /// Third-party items in the overflow whose app isn't known.
    public var unattributedOverflow: Int
    /// The « button is shown.
    public var overflowIndicator: Bool

    /// macOS's overflow is in use: shown items didn't fit.
    public var overflowSeen: Bool { overflowIndicator || !overflowedApps.isEmpty || unattributedOverflow > 0 }

    /// Overlap (in points) beyond which two frames can't both be where they say.
    static let overlapTolerance = 1.0

    /// - Parameters:
    ///   - items: one snapshot of the collapsed menu bar.
    ///   - shownApps: third-party apps whose section is shown now (whether moved out for room or not).
    ///   - planned: the shown apps being planned (measured, not moved out now): only their items measure gaps.
    ///   - isOnScreen: whether SnugBar lets an app's items through now.
    ///   - notch: the camera housing on the bar's screen, if any.
    ///   - overflowIndicator: whether the snapshot has the « button.
    public static func make(
        items: [MenuBarItem], ownBundleID: String, shownApps: Set<String>, planned: Set<String>,
        isOnScreen: (String) -> Bool, notch: Rect? = nil, overflowIndicator: Bool = false
    ) -> FitSurvey {
        func behindNotch(_ r: Rect) -> Bool {
            guard let notch, notch.width > 0 else { return false }
            return min(r.maxX, notch.maxX) - max(r.minX, notch.minX) > overlapTolerance
        }
        var ignored: [(Int, Reason)] = []
        var overflowed = Set<String>()
        var unattributed = 0
        // First pass: what is off screen, and which apps have items in the overflow.
        var candidates: [Int] = []
        for (i, item) in items.enumerated() {
            let fixed = item.isAppleItem || item.ownerBundleID == ownBundleID
            let owner = item.ownerBundleID
            if !fixed, owner.isEmpty {
                if item.isOverflowed { unattributed += 1 }
                ignored.append((i, .unknownOwner))
                continue
            }
            if !fixed, !isOnScreen(owner) { ignored.append((i, .notAllowed)); continue }
            if item.isOverflowed {
                if !fixed, shownApps.contains(owner) { overflowed.insert(owner) }
                ignored.append((i, .overflowed))
                continue
            }
            if item.frame.width <= 0 { ignored.append((i, .noWidth)); continue }
            if behindNotch(item.frame) {
                if !fixed, shownApps.contains(owner) { overflowed.insert(owner) }
                ignored.append((i, .behindNotch))
                continue
            }
            candidates.append(i)
        }
        // Second pass: items of apps partly in the overflow, and of apps not planned.
        var onScreen: [Int] = []
        for i in candidates {
            let item = items[i]
            if item.isAppleItem || item.ownerBundleID == ownBundleID { onScreen.append(i); continue }
            if overflowed.contains(item.ownerBundleID) { ignored.append((i, .appOverflowed)); continue }
            if !planned.contains(item.ownerBundleID) { ignored.append((i, .notPlanned)); continue }
            onScreen.append(i)
        }
        // Overlaps: drop the third-party item overlapping its neighbours most, until nothing overlaps.
        func isFixed(_ i: Int) -> Bool { items[i].isAppleItem || items[i].ownerBundleID == ownBundleID }
        func overlap(_ a: Int, _ b: Int) -> Double {
            let x = min(items[a].frame.maxX, items[b].frame.maxX) - max(items[a].frame.minX, items[b].frame.minX)
            return x > overlapTolerance ? x : 0
        }
        while true {
            var worst: (index: Int, total: Double)?
            for a in onScreen where !isFixed(a) {
                let total = onScreen.reduce(0.0) { $1 == a ? $0 : $0 + overlap(a, $1) }
                if total > 0, total >= (worst?.total ?? 0) { worst = (a, total) }
            }
            guard let worst else { break }
            onScreen.removeAll { $0 == worst.index }
            ignored.append((worst.index, .overlaps))
        }
        let fixed = onScreen.filter(isFixed).map { items[$0] }
        let thirdParty = onScreen.filter { !isFixed($0) }.map { items[$0] }
        let geometry = FitPlanner.Geometry.measure(fixed: fixed.map(\.frame), thirdParty: thirdParty.map(\.frame))
        let appleGap = FitPlanner.typicalGap(fixed.filter(\.isAppleItem).map(\.frame))
        let list = ignored.sorted { a, b in
            let fa = items[a.0].frame.minX, fb = items[b.0].frame.minX
            return fa != fb ? fa < fb : a.0 < b.0
        }.map { i, reason in
            Ignored(id: items[i].id.rawValue, bundleID: items[i].ownerBundleID, x: items[i].frame.x,
                    width: items[i].frame.width, reason: reason)
        }
        return FitSurvey(
            geometry: geometry, fixedWidth: fixed.reduce(0) { $0 + $1.frame.width }, fixedItemCount: fixed.count,
            appleGap: appleGap, ignored: list, overflowedApps: overflowed.sorted(), unattributedOverflow: unattributed,
            overflowIndicator: overflowIndicator
        )
    }
}

/// One "Didn't fit" check of the collapsed menu bar: who is shown, how wide each app is, what the bar measures, and
/// the plan. Pure: the app feeds it a snapshot and its remembered widths, and applies the plan.
public enum FitCheck {
    public struct Input {
        /// One snapshot of the collapsed menu bar.
        public var items: [MenuBarItem]
        /// Widths remembered from collapsed snapshots.
        public var measurements: FitMeasurements
        /// Items remembered from any time they were on screen (`ItemCatalog.itemsByApp`): the width of a shown app that
        /// was never measured collapsed, e.g. one just moved to Shown that macOS put straight into its overflow (its
        /// items can be missing from the menu bar's tree then).
        public var remembered: [String: [MenuBarItem]]
        public var shownApps: Set<String>
        public var ownBundleID: String
        public var isOnScreen: (String) -> Bool
        /// Apps moved out for room now.
        public var movedNow: Set<String>
        public var notch: Rect?
        public var overflowIndicator: Bool
        /// Room for status items; nil when unknown (then there is no plan).
        public var availableWidth: Double?
        /// Room the estimate is known to miss on this bar (`FitSafetyNet.shortfall`), taken off `availableWidth`.
        public var shortfall: Double

        public init(
            items: [MenuBarItem], measurements: FitMeasurements, remembered: [String: [MenuBarItem]] = [:],
            shownApps: Set<String>, ownBundleID: String, isOnScreen: @escaping (String) -> Bool = { _ in true },
            movedNow: Set<String> = [], notch: Rect? = nil, overflowIndicator: Bool = false, availableWidth: Double?,
            shortfall: Double = 0
        ) {
            self.items = items
            self.measurements = measurements
            self.remembered = remembered
            self.shownApps = shownApps
            self.ownBundleID = ownBundleID
            self.isOnScreen = isOnScreen
            self.movedNow = movedNow
            self.notch = notch
            self.overflowIndicator = overflowIndicator
            self.availableWidth = availableWidth
            self.shortfall = shortfall
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public var survey: FitSurvey
        /// Shown apps with a known width, left to right (apps off the bar first).
        public var apps: [FitPlanner.App]
        /// Shown apps whose width isn't known (never seen on screen), so they don't count.
        public var unmeasured: [String]
        /// Shown apps counted with remembered widths because none of their items is in the bar's tree now, though
        /// SnugBar lets them through (macOS keeps them in its overflow).
        public var offBar: [String]
        public var shortfall: Double
        public var plan: FitPlanner.Plan?
    }

    public static func run(_ input: Input) -> Result {
        var measurements = input.measurements
        let liveApps = Set(input.items.filter { !$0.isAppleItem && !$0.ownerBundleID.isEmpty }.map(\.ownerBundleID))
        let candidates = input.shownApps.subtracting([input.ownBundleID])
        // Shown, let through, not moved out, and yet none of its items is in the tree: macOS keeps it off the bar.
        let offBar = candidates.filter { !liveApps.contains($0) && !input.movedNow.contains($0) && input.isOnScreen($0) }
        measurements.adopt(input.remembered, for: candidates.subtracting(liveApps))
        measurements.markOffBar(offBar)
        let apps = measurements.ordered(candidates)
        let planned = Set(apps.map(\.bundleID)).subtracting(input.movedNow)
        let survey = FitSurvey.make(
            items: input.items, ownBundleID: input.ownBundleID, shownApps: candidates.subtracting(input.movedNow),
            planned: planned, isOnScreen: input.isOnScreen, notch: input.notch, overflowIndicator: input.overflowIndicator
        )
        let shortfall = max(input.shortfall, 0)
        let plan = input.availableWidth.map {
            FitPlanner.plan(apps: apps, geometry: survey.geometry, availableWidth: max($0 - shortfall, 0), movedNow: input.movedNow)
        }
        return Result(
            survey: survey, apps: apps, unmeasured: candidates.subtracting(apps.map(\.bundleID)).sorted(),
            offBar: offBar.filter { measurements.apps[$0] != nil }.sorted(), shortfall: shortfall, plan: plan
        )
    }
}

/// The SPEC's rule of thumb as a last resort: if macOS's own overflow shows in the collapsed bar, something didn't fit,
/// whatever the estimate says. Then the leftmost shown app moves out anyway, and the room the estimate missed is
/// remembered for this bar so the app doesn't come straight back. Bounded: at most `maxRounds` moves per `window`.
public struct FitSafetyNet: Sendable {
    public static let maxRounds = 3
    public static let window: TimeInterval = 60
    /// How long the bar must have been left alone before its overflow counts (items take a moment to move).
    public static let settleTime: TimeInterval = 2

    public enum Verdict: Equatable, Sendable {
        /// macOS's overflow isn't in use.
        case quiet
        /// The plan moves apps itself; check again once that settled.
        case planMoves
        /// The bar changed a moment ago: check again once it settled.
        case settling
        /// The user is ⌘-dragging or an item is being opened.
        case userBusy
        /// Overflow seen, but every shown app is out already.
        case nothingToMove
        /// `maxRounds` moves in the last `window`: stop until the next minute.
        case roundLimit
        /// Move this app (the leftmost still shown).
        case fire(String)

        public var label: String {
            switch self {
            case .quiet: return "quiet: macOS's overflow is not in use"
            case .planMoves: return "not needed: the plan moves apps itself"
            case .settling: return "waiting: the menu bar changed a moment ago"
            case .userBusy: return "waiting: the user is dragging items or opening one"
            case .nothingToMove: return "overflow seen, but no shown app is left to move"
            case .roundLimit: return "stopped: \(FitSafetyNet.maxRounds) moves in the last minute"
            case let .fire(app): return "fires: overflow seen while the plan says everything fits; moves \(app)"
            }
        }
    }

    public private(set) var rounds: [Date] = []
    /// Room the estimate missed on the bar `shortfallKey` describes.
    public private(set) var shortfall: Double = 0
    public private(set) var shortfallKey: String?

    public init() {}

    /// The room to take off the estimate for this bar. A different bar (screen, room or set of shown apps) starts
    /// afresh.
    public mutating func shortfall(for key: String) -> Double {
        if key != shortfallKey {
            shortfallKey = key
            shortfall = 0
        }
        return shortfall
    }

    /// What the safety net would do, without the round limit.
    /// - Parameters:
    ///   - movedNow: apps out for room now.
    ///   - settled: the bar was left alone for `settleTime`.
    ///   - userBusy: the user ⌘-drags items or an item is being opened.
    public static func verdict(
        survey: FitSurvey, plan: FitPlanner.Plan?, movedNow: Set<String>, settled: Bool, userBusy: Bool
    ) -> Verdict {
        guard survey.overflowSeen else { return .quiet }
        guard let plan else { return .nothingToMove }
        if !Set(plan.moved).isSubset(of: movedNow) { return .planMoves }
        if userBusy { return .userBusy }
        if !settled { return .settling }
        guard let leftmost = plan.kept.first else { return .nothingToMove }
        return .fire(leftmost)
    }

    /// The verdict with the round limit; a `fire` is counted and the room the estimate missed is learnt (the room it
    /// thought was left, plus a point).
    public mutating func decide(
        survey: FitSurvey, plan: FitPlanner.Plan?, movedNow: Set<String>, settled: Bool, userBusy: Bool, now: Date
    ) -> Verdict {
        let verdict = Self.verdict(survey: survey, plan: plan, movedNow: movedNow, settled: settled, userBusy: userBusy)
        guard case .fire = verdict, let plan else { return verdict }
        rounds = rounds.filter { now.timeIntervalSince($0) < Self.window }
        guard rounds.count < Self.maxRounds else { return .roundLimit }
        rounds.append(now)
        shortfall += max(plan.availableWidth - plan.keptWidth, 0) + 1
        return verdict
    }
}
