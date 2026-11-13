import AppKit
import SnugBarCore
import SnugBarEngine

/// Everything that went into a "Didn't fit" decision. Shared by the app and the `fit-plan` debug command.
struct FitAnalysis: Encodable {
    var space: MenuBarSpace?
    /// Room taken by items that always stay (Apple's items and SnugBar's own).
    var fixedWidth: Double
    var fixedItemCount: Int
    var itemSpacing: Double
    /// Shown third-party apps with a known width, left to right.
    var apps: [FitPlanner.App]
    /// Shown apps whose width isn't known (never seen on screen), so they don't count.
    var unmeasured: [String]
    var plan: FitPlanner.Plan?

    @MainActor
    static func make(items: [MenuBarItem], measurements: FitMeasurements, shownApps: Set<String>, ownBundleID: String) -> FitAnalysis {
        let space = MenuBarSpaceProbe.space(for: items)
        let fixed = items.filter { $0.isAppleItem || $0.ownerBundleID == ownBundleID }
        let fixedWidth = fixed.reduce(0) { $0 + $1.frame.width }
        // Apple's items always sit side by side on the right, so their gaps are the bar's spacing.
        let spacing = FitPlanner.typicalGap(items.filter { $0.isAppleItem && !$0.isOverflowed }.map(\.frame))
        let apps = measurements.ordered(shownApps)
        let plan = space.map {
            FitPlanner.plan(
                apps: apps, fixedWidth: fixedWidth, fixedItemCount: fixed.count,
                availableWidth: $0.availableWidth, itemSpacing: spacing
            )
        }
        return FitAnalysis(
            space: space, fixedWidth: fixedWidth, fixedItemCount: fixed.count, itemSpacing: spacing, apps: apps,
            unmeasured: shownApps.subtracting(apps.map(\.bundleID)).sorted(), plan: plan
        )
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

    /// Third-party apps that own an item now (live or remembered) and are running.
    static func appsWithItems(live: [MenuBarItem], measurements: FitMeasurements, running: Set<String>, ownBundleID: String) -> Set<String> {
        var result = Set(live.filter { !$0.isAppleItem && !$0.ownerBundleID.isEmpty }.map(\.ownerBundleID))
        result.formUnion(measurements.apps.keys)
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
