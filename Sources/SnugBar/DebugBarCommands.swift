import AppKit
import SnugBarCore
import SnugBarEngine

/// Read-only debug commands for the SnugBar Bar, "Didn't fit", search and open by letter. They read the menu bar,
/// the settings file and the image cache, and change nothing.
///
/// This process doesn't share the running app's runtime state, so it assumes the menu bar is collapsed and not
/// swapped, and plans "Didn't fit" from the widths it can see now (the running app also remembers widths of apps it
/// has already moved out).
extension DebugRunner {
    /// What the debug commands work from.
    struct BarContext {
        var settings: Settings
        var ownBundleID: String
        var live: [MenuBarItem]
        var problem: String?
        var analysis: FitAnalysis
        /// Apps "Didn't fit" would hold (empty when the setting is off).
        var overflow: Set<String>
        /// Every item: live ones plus placeholders for running known apps that aren't in the tree.
        var items: [MenuBarItem]
        /// The system order file, when readable (finds pictures saved under an item's other ID).
        var orderPositions: [String: Double]?

        func appName(_ bundleID: String) -> String {
            live.first { $0.ownerBundleID == bundleID }?.appName ?? settings.knownApps[bundleID] ?? bundleID
        }
    }

    func barContext() -> BarContext {
        let settings = (try? SettingsStore(url: SettingsStore.defaultURL).load()) ?? .default
        let own = Bundle.main.bundleIdentifier ?? "app.snugbar.SnugBar"
        var live: [MenuBarItem] = []
        var problem: String?
        let positions = try? orderFile.readPositions()
        if Permissions.accessibility {
            let snap = reader.snapshot(orderPositions: positions)
            live = snap.items
            problem = snap.problem
        } else {
            problem = "accessibility not granted: no live items; hidden items come from known apps only"
        }
        let running = ItemGathering.runningBundleIDs()
        let candidates = ItemGathering.appsWithItems(live: live, measurements: FitMeasurements(), running: running, ownBundleID: own)
        let shown = VisibilityPlanner.collapsedVisibleApps(state: .initial, sections: settings.sections, candidates: candidates, excluding: [own])
        var measurements = FitMeasurements()
        measurements.record(live, excluding: [own], isOnScreen: { shown.contains($0) })
        let analysis = FitAnalysis.make(items: live, measurements: measurements, shownApps: shown, ownBundleID: own)
        let overflow: Set<String> = settings.moveItemsThatDontFit ? Set(analysis.plan?.moved ?? []) : []
        let items = ItemCatalog().merged(live: live, running: running, knownApps: settings.knownApps)
            .filter { $0.ownerBundleID != own }
        return BarContext(settings: settings, ownBundleID: own, live: live, problem: problem, analysis: analysis,
                          overflow: overflow, items: items, orderPositions: positions)
    }

    /// The groups as the bar tiles them: an app's items without a picture share one tile.
    private func tiledGroups(_ c: BarContext, imager: ItemImager) -> [(kind: BarGroupKind, tiles: [BarTile])] {
        groups(c).map { group in
            (group.kind, BarListing.tiles(for: group.items) { imager.keyedImage(for: $0.id, orderPositions: c.orderPositions) != nil })
        }
    }

    /// `--all` lists Always hidden too, as when everything is revealed.
    private var barState: BarState {
        BarState(reveal: invocation.arguments.contains("--all") ? .all : .expanded, revealInBar: true)
    }

    private func groups(_ c: BarContext) -> [BarGroup] {
        BarListing.groups(items: c.items, sections: c.settings.sections, state: barState, overflowHidden: c.overflow,
                          excluding: [c.ownBundleID])
    }

    // MARK: - fit-plan

    struct FitPlanResult: Encodable {
        struct Screen: Encodable {
            var name: String
            var menuBar: Rect
            var notch: Rect?
            var primary: Bool
        }
        struct App: Encodable { var bundleID: String; var name: String; var width: Double; var items: Int }

        var moveItemsThatDontFit: Bool
        var problem: String?
        var screens: [Screen]
        var space: MenuBarSpace?
        var fixedWidth: Double
        var fixedItemCount: Int
        var itemSpacing: Double
        /// Shown apps considered, left to right.
        var shownApps: [App]
        var unmeasured: [String]
        var plan: FitPlanner.Plan?
        /// Apps that would be listed under "Didn't fit" (empty when the setting is off).
        var wouldMoveToDidntFit: [App]
    }

    /// `fit-plan`: menu bar geometry, shown widths and what would go to "Didn't fit". Changes nothing.
    func fitPlan() -> FitPlanResult {
        let c = barContext()
        let screens = zip(NSScreen.screens, MenuBarScreens.strips()).map { screen, strip in
            FitPlanResult.Screen(name: screen.localizedName, menuBar: Self.rect(strip.frame), notch: strip.notch.map(Self.rect),
                                 primary: strip.isPrimary)
        }
        let apps = c.analysis.apps.map { FitPlanResult.App(bundleID: $0.bundleID, name: c.appName($0.bundleID), width: $0.width, items: $0.itemCount) }
        return FitPlanResult(
            moveItemsThatDontFit: c.settings.moveItemsThatDontFit,
            problem: c.problem,
            screens: screens,
            space: c.analysis.space,
            fixedWidth: c.analysis.fixedWidth,
            fixedItemCount: c.analysis.fixedItemCount,
            itemSpacing: c.analysis.itemSpacing,
            shownApps: apps,
            unmeasured: c.analysis.unmeasured,
            plan: c.analysis.plan,
            wouldMoveToDidntFit: apps.filter { c.overflow.contains($0.bundleID) }
        )
    }

    static func rect(_ r: CGRect) -> Rect {
        Rect(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    // MARK: - search

    struct SearchResult: Encodable {
        struct Row: Encodable {
            var rank: Int
            var id: ItemID
            var name: String
            var app: String
            var bundleID: String
            var match: FuzzyMatcher.Kind?
            var score: Double
            var recentRank: Int?
            var place: String
        }
        var query: String
        var problem: String?
        var recents: [ItemID]
        var count: Int
        var results: [Row]
    }

    /// `search <query>`: ranked results as the palette would list them. An empty query lists recents first.
    func searchItems() -> SearchResult {
        let c = barContext()
        let query = invocation.positional().joined(separator: " ")
        let results = FuzzyMatcher.rank(query, items: c.items, recents: c.settings.recentItems)
        let rows = results.enumerated().map { n, r in
            SearchResult.Row(
                rank: n + 1, id: r.item.id, name: r.item.displayName, app: r.item.appName, bundleID: r.item.ownerBundleID,
                match: r.kind, score: (r.score * 100).rounded() / 100, recentRank: r.recentRank, place: place(r.item, c)
            )
        }
        return SearchResult(query: query, problem: c.problem, recents: c.settings.recentItems, count: rows.count, results: rows)
    }

    private func place(_ item: MenuBarItem, _ c: BarContext) -> String {
        if item.isAppleItem { return "Shown" }
        return BarListing.kind(of: item, sections: c.settings.sections, collapsedVisible: BarState.initial.collapsedSections,
                               overflowHidden: c.overflow)?.title ?? "Shown"
    }

    // MARK: - letters

    struct LettersResult: Encodable {
        struct Row: Encodable { var key: String?; var id: ItemID; var name: String; var group: BarGroupKind }
        var problem: String?
        var keys: [Row]
    }

    /// `letters [--all]`: the key each tile in the SnugBar Bar would get in letter mode.
    func letters() -> LettersResult {
        let c = barContext()
        let groups = tiledGroups(c, imager: ItemImager(cacheDirectory: ItemImager.defaultCacheDirectory))
        let keys = LetterAssigner.assign(groups.flatMap { $0.tiles.map(\.item) })
        let rows = groups.flatMap { group in
            group.tiles.map { LettersResult.Row(key: keys[$0.id].map { String($0) }, id: $0.id, name: $0.helpText, group: group.kind) }
        }
        return LettersResult(problem: c.problem, keys: rows)
    }

    // MARK: - bar-items

    struct BarItemsResult: Encodable {
        struct Item: Encodable {
            var id: ItemID
            var name: String
            var app: String
            var bundleID: String
            /// `cache` (a picture captured earlier), `icon` (the app's icon) or `none`.
            var imageSource: String
            /// False for a placeholder: a running app whose items aren't in the menu bar tree now.
            var live: Bool
            /// The cache file's ID when the picture was saved under the item's other ID (see `equivalentIDs`).
            var imageFoundUnder: ItemID?
        }
        /// One tile: a single item, or several items of one app that share a tile because none has a picture.
        struct Tile: Encodable { var opens: ItemID; var help: String; var items: [Item] }
        struct Group: Encodable { var group: BarGroupKind; var title: String; var tiles: [Tile] }
        var problem: String?
        var imageCache: String
        var groups: [Group]
    }

    /// `bar-items [--all]`: what the SnugBar Bar would list, per group and tile, with each item's image source.
    func barItems() -> BarItemsResult {
        let c = barContext()
        let imager = ItemImager(cacheDirectory: ItemImager.defaultCacheDirectory)
        let liveIDs = Set(c.live.map(\.id))
        let groups = tiledGroups(c, imager: imager).map { group in
            BarItemsResult.Group(group: group.kind, title: group.kind.title, tiles: group.tiles.map { tile in
                .init(opens: tile.id, help: tile.helpText, items: tile.items.map { item in
                    let found = imager.keyedImage(for: item.id, orderPositions: c.orderPositions)?.0
                    let source = found != nil ? "cache" : (ItemImager.appIcon(for: item) != nil ? "icon" : "none")
                    return .init(id: item.id, name: item.displayName, app: item.appName, bundleID: item.ownerBundleID,
                                 imageSource: source, live: liveIDs.contains(item.id),
                                 imageFoundUnder: found == item.id ? nil : found)
                })
            })
        }
        return BarItemsResult(problem: c.problem, imageCache: ItemImager.defaultCacheDirectory.path, groups: groups)
    }
}
