import AppKit
import SnugBarCore
import SnugBarEngine

/// Everything that went into a "Didn't fit" decision. Shared by the app and the `fit-plan` debug command.
struct FitAnalysis: Encodable {
    var space: MenuBarSpace?
    /// What was measured and what was left out (`FitCheck`), the shown apps and the plan.
    var check: FitCheck.Result
    /// The safety net's verdict for this check (macOS's overflow in use while the plan says everything fits).
    var safetyNet: String?

    var geometry: FitPlanner.Geometry { check.survey.geometry }
    var apps: [FitPlanner.App] { check.apps }
    var unmeasured: [String] { check.unmeasured }
    var plan: FitPlanner.Plan? { check.plan }

    /// - Parameters:
    ///   - remembered: items remembered from any time they were on screen (`ItemCatalog.itemsByApp`).
    ///   - isOnScreen: whether an app's items are on screen now (hidden apps' items linger with stale frames).
    ///   - movedNow: apps out of the menu bar for room now (they need a little extra room to come back).
    ///   - overflowIndicator: the snapshot has macOS's « button.
    ///   - shortfall: the room the safety net learnt the estimate misses on this bar, by bar key (`barKey`).
    @MainActor
    static func make(
        items: [MenuBarItem], measurements: FitMeasurements, remembered: [String: [MenuBarItem]] = [:],
        shownApps: Set<String>, ownBundleID: String, isOnScreen: @escaping (String) -> Bool = { _ in true },
        movedNow: Set<String> = [], overflowIndicator: Bool = false, shortfall: (String) -> Double = { _ in 0 }
    ) -> FitAnalysis {
        let space = MenuBarSpaceProbe.space(for: items)
        let check = FitCheck.run(FitCheck.Input(
            items: items, measurements: measurements, remembered: remembered, shownApps: shownApps,
            ownBundleID: ownBundleID, isOnScreen: isOnScreen, movedNow: movedNow, notch: space?.notch,
            overflowIndicator: overflowIndicator, availableWidth: space?.availableWidth,
            shortfall: space.map { shortfall(barKey($0, shownApps: shownApps)) } ?? 0
        ))
        return FitAnalysis(space: space, check: check)
    }

    /// Identifies a bar for the safety net's learnt shortfall: the screen, its room and the set of shown apps.
    static func barKey(_ space: MenuBarSpace, shownApps: Set<String>) -> String {
        "\(space.screenName)|\(space.availableWidth)|\(shownApps.sorted().joined(separator: ","))"
    }
}

@MainActor
enum ItemGathering {
    /// Bundle IDs of running apps that can own menu bar items.
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { app in
            app.activationPolicy == .prohibited ? nil : app.bundleIdentifier
        })
    }

    /// Third-party apps that own an item now (live, measured or remembered) and are running. Remembered apps count: a
    /// shown app macOS keeps in its overflow can be missing from the menu bar's tree.
    static func appsWithItems(
        live: [MenuBarItem], measurements: FitMeasurements, remembered: Set<String> = [], running: Set<String>, ownBundleID: String
    ) -> Set<String> {
        var result = Set(live.filter { !$0.isAppleItem && !$0.ownerBundleID.isEmpty }.map(\.ownerBundleID))
        result.formUnion(measurements.apps.keys)
        result.formUnion(remembered)
        return result.intersection(running).subtracting([ownBundleID])
    }
}

extension BarGroupKind {
    var title: String {
        switch self {
        case .hidden: return "Hidden"
        case .alwaysHidden: return "Always Hidden"
        case .didntFit: return "Didn’t Fit"
        }
    }
}

extension NSImage {
    /// An image for a menu bar item. Captured pictures (bar background already keyed out) are template images when
    /// they are one-colour glyphs, so they are drawn in the label colour and suit light and dark appearances; app icons
    /// keep their colours. Views draw every image aspect-fit in the same box, whatever its size here.
    @MainActor
    static func forBarItem(_ image: ItemImager.ItemImage?) -> NSImage {
        guard let image else {
            let placeholder = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
            placeholder.isTemplate = true
            return placeholder
        }
        let scale: CGFloat = image.source == .appIcon ? 1 : (NSScreen.main?.backingScaleFactor ?? 2)
        let result = NSImage(cgImage: image.image, size: NSSize(width: CGFloat(image.image.width) / scale,
                                                                height: CGFloat(image.image.height) / scale))
        result.isTemplate = image.isTemplate
        return result
    }
}
