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
        var indicator = false
        let positions = try? orderFile.readPositions()
        if Permissions.accessibility {
            let snap = reader.snapshot(orderPositions: positions)
            live = snap.items
            problem = snap.problem
            indicator = snap.overflowIndicatorFrame != nil
        } else {
            problem = "accessibility not granted: no live items; hidden items come from known apps only"
        }
        let running = ItemGathering.runningBundleIDs()
        let candidates = ItemGathering.appsWithItems(live: live, measurements: FitMeasurements(), running: running, ownBundleID: own)
        let shown = VisibilityPlanner.collapsedVisibleApps(state: .initial, sections: settings.sections, candidates: candidates, excluding: [own])
        var measurements = FitMeasurements()
        measurements.record(live, excluding: [own], isOnScreen: { shown.contains($0) })
        let analysis = FitAnalysis.make(items: live, measurements: measurements, shownApps: shown, ownBundleID: own,
                                        isOnScreen: { shown.contains($0) }, overflowIndicator: indicator)
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
        /// Median gap between Apple's items (information only).
        var appleGap: Double
        /// What the estimate uses: required = fixedSpan + app widths + junctionGap + thirdPartyGap per boundary
        /// between third-party items + margin.
        var fixedSpan: Double
        var thirdPartyGap: Double
        var junctionGap: Double
        /// Shown third-party items sitting between fixed items (left out of `fixedSpan`, counted with their apps).
        var insideWidth: Double
        /// Items left out of the span and gap measurement, and why (overflowed, behindNotch, noWidth, notAllowed,
        /// notPlanned, appOverflowed, overlaps, unknownOwner).
        var ignoredForMeasurement: [FitSurvey.Ignored]
        /// macOS's overflow in the snapshot: the « button, shown apps with items in it (or behind the notch), and
        /// overflowed items without an owner.
        var overflowIndicator: Bool
        var overflowedApps: [String]
        var unattributedOverflow: Int
        /// Shown apps counted with remembered widths because they are let through but missing from the tree (the
        /// running app only: this process remembers nothing).
        var offBar: [String]
        /// Shown apps considered, left to right.
        var shownApps: [App]
        var unmeasured: [String]
        var plan: FitPlanner.Plan?
        /// Whether the safety net (macOS's overflow in use while the plan says everything fits) would fire now, and
        /// which app it would move. Assumes the bar has settled and nothing is out for room yet.
        var safetyNetWouldFire: Bool
        var safetyNet: String
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
        let survey = c.analysis.check.survey
        let verdict = FitSafetyNet.verdict(survey: survey, plan: c.analysis.plan, movedNow: [], settled: true, userBusy: false)
        var overflow = c.overflow
        if case let .fire(app) = verdict, c.settings.moveItemsThatDontFit { overflow.insert(app) }
        return FitPlanResult(
            moveItemsThatDontFit: c.settings.moveItemsThatDontFit,
            problem: c.problem,
            screens: screens,
            space: c.analysis.space,
            fixedWidth: survey.fixedWidth,
            fixedItemCount: survey.fixedItemCount,
            appleGap: survey.appleGap,
            fixedSpan: survey.geometry.fixedSpan,
            thirdPartyGap: survey.geometry.thirdPartyGap,
            junctionGap: survey.geometry.junctionGap,
            insideWidth: survey.geometry.insideWidth,
            ignoredForMeasurement: survey.ignored,
            overflowIndicator: survey.overflowIndicator,
            overflowedApps: survey.overflowedApps,
            unattributedOverflow: survey.unattributedOverflow,
            offBar: c.analysis.check.offBar,
            shownApps: apps,
            unmeasured: c.analysis.unmeasured,
            plan: c.analysis.plan,
            safetyNetWouldFire: { if case .fire = verdict { return true } else { return false } }(),
            safetyNet: verdict.label,
            wouldMoveToDidntFit: apps.filter { overflow.contains($0.bundleID) }
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

    // MARK: - key-images

    struct KeyImagesResult: Encodable {
        struct File: Encodable {
            var name: String
            var width: Int
            var height: Int
            /// Nil when nothing was left after keying.
            var keyedWidth: Int?
            var keyedHeight: Int?
            var isTemplate: Bool?
            var background: [Double]?
            /// `--map`: the input's rows (`#` close to the background-free glyph, `.` background) and the keyed
            /// alpha (` .:-=+*#%@` from 0 to 1).
            var inputMap: [String]?
            var alphaMap: [String]?
        }
        var from: String
        var to: String?
        var files: [File]
    }

    /// `key-images [--from <dir>] [--to <dir>] [--match <text>] [--map]`: keys the cached captures (default: the image
    /// cache) and, with `--to`, writes `<name>.png` (keyed, as the app keeps it) and `<name>-preview.png` (8× on a dark
    /// tile, templates drawn white) there. Only reads `--from`.
    func keyImages() throws -> KeyImagesResult {
        let from = invocation.value(after: "--from").map { URL(fileURLWithPath: $0) } ?? ItemImager.defaultCacheDirectory
        let to = invocation.value(after: "--to").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let to {
            guard to.standardizedFileURL.path != from.standardizedFileURL.path else { throw Failure("--to must differ from --from") }
            try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        }
        let match = invocation.value(after: "--match")
        let names = try FileManager.default.contentsOfDirectory(atPath: from.path)
            .filter { $0.hasSuffix(".png") && (match == nil || $0.contains(match!)) }
            .sorted()
        var files: [KeyImagesResult.File] = []
        for name in names {
            guard let source = CGImageSourceCreateWithURL(from.appendingPathComponent(name) as CFURL, nil),
                  let raw = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let bitmap = GlyphImage.bitmap(from: raw)
            else { continue }
            let result = GlyphKeyer.key(bitmap)
            var file = KeyImagesResult.File(name: name, width: raw.width, height: raw.height)
            if let result {
                file.keyedWidth = result.bitmap.width
                file.keyedHeight = result.bitmap.height
                file.isTemplate = result.isTemplate
                file.background = result.background.map { [$0.r, $0.g, $0.b] }
                if invocation.arguments.contains("--map") {
                    file.inputMap = Self.lumaMap(bitmap)
                    file.alphaMap = Self.alphaMap(result.bitmap)
                }
                if let to, let keyed = GlyphImage.cgImage(from: result.bitmap) {
                    let base = to.appendingPathComponent((name as NSString).deletingPathExtension)
                    try keyed.pngData()?.write(to: base.appendingPathExtension("png"), options: .atomic)
                    try Self.preview(result)?.pngData()?.write(to: URL(fileURLWithPath: base.path + "-preview.png"), options: .atomic)
                }
            }
            files.append(file)
        }
        return KeyImagesResult(from: from.path, to: to?.path, files: files)
    }

    private static let ramp = Array(" .:-=+*#%@")

    private static func alphaMap(_ b: GlyphKeyer.Bitmap) -> [String] {
        (0..<b.height).map { y in
            String((0..<b.width).map { x in ramp[min(Int(Double(b.pixel(x: x, y: y).a) / 256 * Double(ramp.count)), ramp.count - 1)] })
        }
    }

    private static func lumaMap(_ b: GlyphKeyer.Bitmap) -> [String] {
        (0..<b.height).map { y in
            String((0..<b.width).map { x in
                let p = b.pixel(x: x, y: y)
                let luma = (Double(p.r) + Double(p.g) + Double(p.b)) / 3
                return ramp[min(Int(luma / 256 * Double(ramp.count)), ramp.count - 1)]
            })
        }
    }

    /// The keyed picture 8× on a dark tile, as the bar would draw it (templates in white).
    private static func preview(_ result: GlyphKeyer.Result) -> CGImage? {
        let scale = 8
        let b = result.bitmap
        let w = (b.width + 4) * scale, h = (b.height + 4) * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let keyed = GlyphImage.cgImage(from: b),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rect = CGRect(x: 2 * scale, y: 2 * scale, width: b.width * scale, height: b.height * scale)
        if result.isTemplate {
            ctx.saveGState()
            ctx.clip(to: rect, mask: keyed)
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
            ctx.restoreGState()
        } else {
            ctx.draw(keyed, in: rect)
        }
        return ctx.makeImage()
    }
}
