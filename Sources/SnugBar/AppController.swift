import AppKit
import Combine
import SnugBarCore
import SnugBarEngine

/// The app's state and the glue between settings, the engine and the UI.
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var settings: Settings
    @Published private(set) var state = BarState.initial
    @Published private(set) var lastError: String?
    @Published private(set) var accessibilityGranted = Permissions.accessibility
    @Published private(set) var screenRecordingGranted = Permissions.screenRecording
    @Published private(set) var orderFileGranted = false
    @Published private(set) var loginItemEnabled = LoginItem.isEnabled
    @Published private(set) var loginItemNeedsApproval = LoginItem.needsApproval
    @Published private(set) var hotkeyFailures: [String] = []
    /// Apps currently visible in the menu bar (from the last snapshot), for the Sections list.
    @Published private(set) var visibleApps: [String: String] = [:]
    /// Shown apps moved out of the menu bar because they don't fit beside the notch (features 17–18). Runtime only.
    @Published private(set) var overflowHidden: Set<String> = []

    let ownBundleID = Bundle.main.bundleIdentifier ?? "app.snugbar.SnugBar"
    /// SnugBar's icon in AppKit screen coordinates, when it is shown. Set by the status item.
    var iconFrame: (() -> NSRect?)?

    private let reader = MenuBarReader()
    private let assessment = AssessmentHider()
    private let divider = OverflowDividerHider()
    private let orderFile = OrderFileAccess()
    private let hotkeys = HotkeyCenter()
    private lazy var notificationGuard = NotificationCenterGuard(hider: assessment, reader: reader)
    private lazy var monitor = MenuBarEventMonitor(reader: reader)
    private lazy var activator = makeActivator()
    private let imager = ItemImager(cacheDirectory: ItemImager.defaultCacheDirectory)
    private let bar = SnugBarBarController()
    private let search = SearchPanelController()
    private let store = SettingsStore(url: SettingsStore.defaultURL)
    private var activeHider: Hider?
    /// Bundle IDs allowed by the current plan, or nil when nothing is hidden.
    private var currentAllowed: Set<String>?
    private var collapseTimer: Timer?
    private var barRefreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var saveScheduled = false
    /// Items seen while visible, so hidden apps can be listed and searched.
    private var catalog = ItemCatalog()
    /// Widths of shown apps, kept while SnugBar has moved them out.
    private var measurements = FitMeasurements()
    private(set) var lastFit: FitAnalysis?
    private var fitWork: DispatchWorkItem?
    private var captureInFlight = false
    /// An item is being opened (focus, synthetic click, pointer put back); reveal gestures are ignored until shortly
    /// after, so nothing SnugBar does on the user's behalf reopens the SnugBar Bar over the item's menu.
    private var activationsInFlight = 0
    private var gesturesQuietUntil = Date.distantPast
    /// The settings file exists but couldn't be read: only an explicit change by the user may replace it.
    private var loadFailed = false

    init() {
        do {
            settings = try store.load()
        } catch {
            settings = .default
            loadFailed = true
            lastError = "Settings file not loaded (\(error)). Using defaults; the file is left untouched until you change a setting."
        }
        orderFileGranted = orderFile.status == .granted
    }

    // MARK: - Lifecycle

    func start() {
        noteVisibleApps()
        hotkeys.onPress = { [weak self] action in self?.perform(action) }
        applyHotkeys()
        configureMonitor()
        configurePanels()
        observeSystem()
        if preferredHider().backend == .overflowDivider { divider.install() }
        applyVisibility()
        scheduleFitCheck(after: 1.5)
    }

    /// Stops hiding so the bar is whole when SnugBar quits (the system would also end the hide on exit).
    func stop() {
        collapseTimer?.invalidate()
        barRefreshTimer?.invalidate()
        bar.dismiss()
        search.dismiss()
        notificationGuard.stop()
        monitor.stop()
        hotkeys.unregisterAll()
        activeHider?.show()
        activeHider = nil
    }

    // MARK: - Commands

    var isRunningFromApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    var backendDescription: String {
        switch preferredHider().backend {
        case .assessment: return "Hiding whole apps (system)"
        case .overflowDivider:
            return assessment.isAvailable ? "Hiding with the divider" : "Hiding with the divider (per-app hiding unavailable)"
        }
    }

    var supportsSwap: Bool { preferredHider().supportsAllowList }

    /// - Parameter focusBar: when the reveal opens the SnugBar Bar, give it keyboard focus. Pointer gestures (hover,
    ///   scroll, a click on the empty bar) pass false so typing stays in the frontmost app.
    func toggle(focusBar: Bool = true) { setReveal(state.reveal == .collapsed ? .expanded : .collapsed, focusBar: focusBar) }

    func toggleAlwaysHidden() { setReveal(state.reveal == .all ? .collapsed : .all) }

    func expand(focusBar: Bool = true) { if state.reveal == .collapsed { setReveal(.expanded, focusBar: focusBar) } }

    func collapse() { setReveal(.collapsed) }

    func swap() {
        guard supportsSwap, !state.zen else { return }
        bar.dismiss()
        state.swapped.toggle()
        state.reveal = .collapsed
        state.revealInBar = false
        collapseTimer?.invalidate()
        applyVisibility()
        // The collapsed bar now shows other apps: check that they fit once they've appeared.
        scheduleFitCheck(after: 1.5)
    }

    /// - Parameter letters: open the SnugBar Bar in letter mode, whatever the "show hidden items in" setting.
    func setReveal(_ level: RevealLevel, focusBar: Bool = true, letters: Bool = false) {
        // Zen locks every way of revealing.
        if state.zen && level != .collapsed { return }
        let wasMenuBarRevealed = state.menuBarReveal != .collapsed
        let inBar = level != .collapsed && (letters || settings.revealIn == .snugBarBar)
        state.reveal = level
        state.revealInBar = inBar
        if level == .collapsed { monitor.suppressHoverUntilPointerLeaves() }
        applyVisibility()
        scheduleAutoCollapse()
        if inBar {
            showBar(letters: letters, focus: focusBar || letters)
        } else {
            bar.dismiss()
            barRefreshTimer?.invalidate()
        }
        if state.menuBarReveal != .collapsed {
            // Learn apps that just appeared (only possible while they're visible), and keep their pictures.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.noteVisibleApps()
                self?.captureVisibleItems()
            }
        } else if wasMenuBarRevealed {
            scheduleFitCheck(after: 1.0)
        }
    }

    func perform(_ action: HotkeyAction) {
        // Zen locks every shortcut but its own.
        if state.zen && action != .zen { return }
        switch action {
        case .toggleHidden: toggle()
        case .toggleAlwaysHidden: toggleAlwaysHidden()
        case .swap: swap()
        case .search: showSearch()
        case .openByLetter: openByLetter()
        case .zen: toggleZen()
        }
    }

    // MARK: - Zen (features 54, 56)

    func toggleZen() { setZen(!state.zen) }

    /// Zen hides every third-party app but SnugBar and locks every reveal. Apple's items (clock, Control Center and
    /// the camera and microphone indicators) stay. Not saved: SnugBar always starts out of Zen.
    func setZen(_ on: Bool) {
        guard on != state.zen else { return }
        bar.dismiss()
        search.dismiss()
        barRefreshTimer?.invalidate()
        collapseTimer?.invalidate()
        state.zen = on
        state.reveal = .collapsed
        state.revealInBar = false
        monitor.suppressHoverUntilPointerLeaves()
        applyVisibility()
        if !on { scheduleFitCheck(after: 1.5) }
    }

    // MARK: - SnugBar Bar, search and open by letter (features 16, 20–28)

    /// Opens the SnugBar Bar with a key on each item; typing a key opens that item.
    func openByLetter() {
        guard !state.zen else { return }
        search.dismiss()
        if state.reveal == .collapsed || !state.revealInBar || !bar.isVisible {
            setReveal(state.reveal == .collapsed ? .expanded : state.reveal, letters: true)
        } else {
            showBar(letters: true, focus: true)
        }
    }

    func showSearch() {
        guard !state.zen else { return }
        if state.revealInBar && state.reveal != .collapsed { collapse() }
        search.show()
    }

    /// Opens an item's menu (ItemActivator: focus it if hidden, then click it) and remembers it as recent.
    ///
    /// The SnugBar Bar and the search palette are ordered out first, before anything is focused or clicked, and stay
    /// closed: the item's menu must be the only thing on screen.
    func activate(_ item: MenuBarItem) {
        guard !state.zen else { return }
        bar.dismiss()
        search.dismiss()
        barRefreshTimer?.invalidate()
        activationsInFlight += 1
        if state.revealInBar && state.reveal != .collapsed { collapse() }
        update { $0.noteRecent(item.id) }
        let positions = try? orderFile.readPositions()
        Task { @MainActor in
            defer {
                self.activationsInFlight -= 1
                // The synthetic click's mouse-up and the pointer warp land a moment later.
                self.gesturesQuietUntil = Date().addingTimeInterval(0.6)
            }
            do {
                _ = try await self.activator.activate(item, orderPositions: positions)
            } catch {
                NSLog("SnugBar: could not open %@: %@", item.id.rawValue, String(describing: error))
                NSSound.beep()
            }
        }
    }

    /// True while an item is being opened, and briefly after.
    private var isActivating: Bool { activationsInFlight > 0 || Date() < gesturesQuietUntil }

    /// Every item SnugBar knows (live, remembered, and placeholders for running apps), without SnugBar's own.
    func allItems() -> [MenuBarItem] {
        let live = Permissions.accessibility ? snapshotItems() : []
        return catalog.merged(live: live, running: ItemGathering.runningBundleIDs(), knownApps: settings.knownApps)
            .filter { $0.ownerBundleID != ownBundleID }
    }

    /// Where an item lives, for the search list.
    func placeDescription(of item: MenuBarItem) -> String {
        if item.isAppleItem { return "Shown" }
        let kind = BarListing.kind(
            of: item, sections: settings.sections, collapsedVisible: state.collapsedSections, overflowHidden: effectiveOverflow
        )
        return kind?.title ?? "Shown"
    }

    private func makeActivator() -> ItemActivator {
        let activator = ItemActivator(reader: reader, hider: assessment.isAvailable ? assessment : nil)
        // The item is visible now (it may never be otherwise): keep its picture for the bar, once.
        activator.beforeClick = { [weak self] item, visibleItems in
            guard let self else { return }
            // Remember the focused app's real items (it may have been listed by a placeholder until now).
            self.catalog.record(visibleItems.filter { $0.ownerBundleID == item.ownerBundleID }, isOnScreen: { _ in true })
            guard !self.imager.hasCachedImage(for: item.id, orderPositions: try? self.orderFile.readPositions()),
                  Permissions.screenRecording else { return }
            _ = try? await self.imager.refresh(visibleItems)
        }
        return activator
    }

    private func configurePanels() {
        bar.onActivate = { [weak self] item in self?.activate(item) }
        bar.onDismiss = { [weak self] in
            guard let self, self.state.revealInBar, self.state.reveal != .collapsed else { return }
            self.collapse()
        }
        bar.onClickOutside = { [weak self] point in
            guard let self else { return }
            // A click on an empty part of the menu bar toggles through the reveal gesture; leave it to that.
            if self.settings.reveal.clickEmptyBar, MenuBarScreens.strip(containing: point) != nil, self.monitor.isEmpty(point) { return }
            self.bar.dismiss()
            if self.state.revealInBar, self.state.reveal != .collapsed { self.collapse() }
        }
        search.source = { [weak self] in
            guard let self else { return .init(items: [], recents: []) }
            return .init(items: self.allItems(), recents: self.settings.recentItems)
        }
        search.detail = { [weak self] item in self?.placeDescription(of: item) ?? "" }
        search.image = { [weak self] item in
            NSImage.forBarItem(self?.imager.image(for: item, orderPositions: try? self?.orderFile.readPositions()))
        }
        search.onActivate = { [weak self] item in self?.activate(item) }
    }

    private func barGroups(letters: Bool) -> [SnugBarBarController.Group] {
        let groups = BarListing.groups(
            items: allItems(), sections: settings.sections, state: state, overflowHidden: effectiveOverflow, excluding: [ownBundleID]
        )
        let positions = try? orderFile.readPositions()
        var images: [ItemID: ItemImager.ItemImage] = [:]
        for item in groups.flatMap(\.items) { images[item.id] = imager.image(for: item, orderPositions: positions) }
        // An app's items without a picture of their own would all show its icon: they share one tile.
        let tiled = groups.map { group in
            (group.kind, BarListing.tiles(for: group.items) { item in
                images[item.id].map { $0.source != .appIcon } ?? false
            })
        }
        let keys = letters ? LetterAssigner.assign(tiled.flatMap { $0.1.map(\.item) }) : [:]
        return tiled.map { kind, tiles in
            SnugBarBarController.Group(kind: kind, entries: tiles.map { tile in
                .init(tile: tile, image: NSImage.forBarItem(images[tile.id]), key: keys[tile.id])
            })
        }
    }

    private func showBar(letters: Bool, focus: Bool) {
        let groups = barGroups(letters: letters)
        var keys: [ItemID: Character] = [:]
        for entry in groups.flatMap(\.entries) { if let key = entry.key { keys[entry.id] = key } }
        bar.show(groups: groups, keys: keys, anchor: iconFrame?(), focus: focus)
        // While the bar is open, pick up items that come and go (no polling otherwise). Letter mode keeps its keys.
        barRefreshTimer?.invalidate()
        guard !letters else { return }
        barRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.bar.isVisible, !self.bar.isShowingKeys else { timer.invalidate(); return }
                self.bar.update(groups: self.barGroups(letters: false))
            }
        }
    }

    /// Captures pictures of the items on screen now (needs Screen Recording). Hidden items can't be captured, so
    /// this runs when items are visible: after a reveal in the menu bar, and before apps move to "Didn't fit".
    private func captureVisibleItems(then done: (() -> Void)? = nil) {
        guard Permissions.screenRecording, Permissions.accessibility, !captureInFlight,
              !assessment.isFocusing, !assessment.isSuspended
        else { done?(); return }
        let onScreen = currentAllowed
        let items = reader.snapshot(orderPositions: try? orderFile.readPositions()).items.filter { item in
            item.isAppleItem || onScreen?.contains(item.ownerBundleID) ?? true
        }
        captureInFlight = true
        Task { @MainActor in
            _ = try? await self.imager.refresh(items)
            self.captureInFlight = false
            done?()
        }
    }

    // MARK: - Fit beside the notch (features 17–18)

    /// Apps moved out for room, when the setting is on and the hider can do it.
    private var effectiveOverflow: Set<String> {
        settings.moveItemsThatDontFit && preferredHider().supportsAllowList ? overflowHidden : []
    }

    /// Re-plans which shown apps go to "Didn't fit" after things settle (debounced).
    func scheduleFitCheck(after delay: TimeInterval = 1.0) {
        fitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.checkFit() }
        }
        fitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkFit() {
        guard settings.moveItemsThatDontFit, preferredHider().supportsAllowList, Permissions.accessibility else {
            if !overflowHidden.isEmpty {
                overflowHidden = []
                applyVisibility()
            }
            return
        }
        // Measure only the collapsed menu bar, and not while an item is being opened or the hide is lifted.
        if state.menuBarReveal != .collapsed { return }
        if assessment.isFocusing || assessment.isSuspended {
            scheduleFitCheck(after: 2)
            return
        }
        let live = snapshotItems()
        let shown = VisibilityPlanner.collapsedVisibleApps(
            state: state, sections: settings.sections,
            candidates: ItemGathering.appsWithItems(live: live, measurements: measurements,
                                                    running: ItemGathering.runningBundleIDs(), ownBundleID: ownBundleID),
            excluding: [ownBundleID]
        )
        let analysis = FitAnalysis.make(items: live, measurements: measurements, shownApps: shown, ownBundleID: ownBundleID)
        lastFit = analysis
        guard analysis.plan != nil else { return }
        let next = Set(analysis.plan?.moved ?? [])
        guard next != overflowHidden else { return }
        let newlyMoved = next.subtracting(overflowHidden)
        let apply = { [weak self] in
            guard let self else { return }
            self.overflowHidden = next
            self.applyVisibility()
            if self.bar.isVisible, !self.bar.isShowingKeys { self.bar.update(groups: self.barGroups(letters: false)) }
        }
        // Keep pictures of apps about to leave the menu bar while they are still on screen.
        let positions = try? orderFile.readPositions()
        let needsCapture = live.contains {
            newlyMoved.contains($0.ownerBundleID) && !$0.isOverflowed && !imager.hasCachedImage(for: $0.id, orderPositions: positions)
        }
        if needsCapture { captureVisibleItems(then: apply) } else { apply() }
    }

    /// One snapshot, also used to remember items and widths of apps that are on screen.
    private func snapshotItems() -> [MenuBarItem] {
        let items = reader.snapshot(orderPositions: try? orderFile.readPositions()).items
        // While an item is being opened or the hide is lifted, other apps' visibility doesn't match the plan.
        guard !assessment.isFocusing, !assessment.isSuspended else { return items }
        let onScreen = currentAllowed
        let isOnScreen: (String) -> Bool = { onScreen?.contains($0) ?? true }
        catalog.record(items, isOnScreen: isOnScreen)
        // Positions only mean something for the collapsed bar: a reveal pushes shown apps into macOS's overflow.
        if state.menuBarReveal == .collapsed {
            measurements.record(items, excluding: [ownBundleID], isOnScreen: isOnScreen)
        }
        return items
    }

    // MARK: - Settings

    /// Changes settings, saves them, and applies what changed.
    func update(_ change: (inout Settings) -> Void) {
        let before = settings
        var next = settings
        change(&next)
        next.autoCollapse.delay = min(max(next.autoCollapse.delay, AutoCollapseSettings.delayRange.lowerBound), AutoCollapseSettings.delayRange.upperBound)
        next.reveal.hoverDelay = min(max(next.reveal.hoverDelay, RevealSettings.hoverDelayRange.lowerBound), RevealSettings.hoverDelayRange.upperBound)
        guard next != before else { return }
        settings = next
        loadFailed = false
        scheduleSave()
        if next.hotkeys != before.hotkeys { applyHotkeys() }
        if next.reveal != before.reveal || next.autoCollapse != before.autoCollapse { configureMonitor() }
        if next.hider != before.hider {
            activeHider?.show()
            activeHider = nil
            notificationGuard.stop()
            if preferredHider().backend == .overflowDivider { divider.install() } else { divider.uninstall() }
        }
        if next.sections != before.sections || next.hider != before.hider { applyVisibility() }
        if next.showIcon != before.showIcon { NotificationCenter.default.post(name: .snugBarIconVisibilityChanged, object: nil) }
        if next.revealIn != before.revealIn, state.reveal != .collapsed { collapse() }
        if next.moveItemsThatDontFit != before.moveItemsThatDontFit {
            if next.moveItemsThatDontFit {
                scheduleFitCheck(after: 0.2)
            } else if !overflowHidden.isEmpty {
                overflowHidden = []
                applyVisibility()
            }
        } else if next.sections != before.sections || next.hider != before.hider || next.showIcon != before.showIcon {
            scheduleFitCheck(after: 1.5)
        }
    }

    func setSection(_ section: Section, for bundleID: String) {
        update { $0.sections.set(section, forBundleID: bundleID) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            lastError = nil
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        loginItemEnabled = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
    }

    func revealSettingsFile() {
        if !FileManager.default.fileExists(atPath: store.url.path) { try? store.save(settings) }
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    /// Apps for the Sections list: every known app plus anything visible now, without Apple's items or SnugBar.
    var sectionRows: [(bundleID: String, name: String)] {
        var all = settings.knownApps
        for (k, v) in visibleApps { all[k] = v }
        for bundle in settings.sections.apps.keys where all[bundle] == nil { all[bundle] = bundle }
        all.removeValue(forKey: ownBundleID)
        return all.map { (bundleID: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Permissions

    func grantAccessibility() {
        Permissions.requestAccessibility()
        refreshPermissions()
    }

    func grantScreenRecording() {
        Permissions.requestScreenRecording()
        refreshPermissions()
    }

    func grantOrderFileAccess() {
        _ = orderFile.requestAccess()
        refreshPermissions()
    }

    func refreshPermissions() {
        let hadAccessibility = accessibilityGranted
        accessibilityGranted = Permissions.accessibility
        screenRecordingGranted = Permissions.screenRecording
        orderFileGranted = orderFile.status == .granted
        refreshLoginItem()
        if accessibilityGranted, !hadAccessibility {
            noteVisibleApps()
            applyVisibility()
        }
    }

    // MARK: - Visibility

    private func preferredHider() -> Hider {
        switch settings.hider {
        case .assessment: return assessment
        case .overflowDivider: return divider
        case .automatic: return assessment.isAvailable ? assessment : divider
        }
    }

    /// Bundle IDs that may own menu bar items now: running apps that can show UI, plus every known app.
    private func candidateBundleIDs() -> Set<String> {
        var result = Set(settings.knownApps.keys)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            if let id = app.bundleIdentifier { result.insert(id) }
        }
        return result
    }

    /// - Parameter force: re-apply even when the allow-list hasn't changed (after wake, display or app changes).
    private func applyVisibility(force: Bool = false) {
        let hider = preferredHider()
        if !hider.supportsAllowList {
            // The divider hides by position: a collapsed menu bar hides, a reveal in the menu bar shows.
            applyDivider(hide: state.menuBarReveal == .collapsed)
            return
        }
        let plan = VisibilityPlanner.plan(
            state: state, sections: settings.sections, candidates: candidateBundleIDs(), alwaysAllowed: [ownBundleID],
            overflowHidden: effectiveOverflow
        )
        switch plan {
        case .showEverything:
            notificationGuard.stop()
            activeHider?.show()
            activeHider = nil
            currentAllowed = nil
            lastError = nil
        case let .allow(allowed):
            // Opening or closing the SnugBar Bar leaves the menu bar as it is; don't replace the hide for nothing.
            if !force, allowed == currentAllowed, activeHider === hider, hider.isHiding, !assessment.isSuspended { return }
            do {
                try hider.hide(allowing: allowed)
                activeHider = hider
                currentAllowed = allowed
                if hider === assessment { notificationGuard.start() }
                lastError = nil
            } catch {
                lastError = "\(error)"
            }
        }
    }

    private func applyDivider(hide: Bool) {
        notificationGuard.stop()
        if hide {
            do {
                try divider.hide(allowing: [])
                activeHider = divider
                lastError = nil
            } catch {
                lastError = "\(error)"
            }
        } else {
            divider.show()
            activeHider = nil
        }
        currentAllowed = nil
    }

    /// Apps visible now that wouldn't be when collapsed.
    private var revealedBundleIDs: Set<String> {
        guard state.reveal != .collapsed else { return [] }
        let collapsed = VisibilityPlanner.plan(
            state: BarState(reveal: .collapsed, swapped: state.swapped), sections: settings.sections,
            candidates: candidateBundleIDs(), alwaysAllowed: [ownBundleID], overflowHidden: effectiveOverflow
        )
        guard case let .allow(base) = collapsed else { return [] }
        return (currentAllowed ?? candidateBundleIDs()).subtracting(base)
    }

    private func revealedMenuOpen() -> Bool {
        let bundles = revealedBundleIDs
        let pids = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
            guard let id = app.bundleIdentifier, bundles.contains(id) else { return nil }
            return app.processIdentifier
        })
        return OpenMenuDetector.isMenuOpenNow(ownerPIDs: pids)
    }

    // MARK: - Auto-collapse

    private func scheduleAutoCollapse(after delay: TimeInterval? = nil) {
        collapseTimer?.invalidate()
        collapseTimer = nil
        guard settings.autoCollapse.enabled, state.reveal != .collapsed else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: delay ?? settings.autoCollapse.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoCollapseTimerFired() }
        }
    }

    private func autoCollapseTimerFired() {
        switch AutoCollapsePolicy.onTimer(
            state: state, settings: settings.autoCollapse,
            menuOpen: revealedMenuOpen(), pointerInMenuBar: MenuBarEventMonitor.pointerInMenuBar || bar.containsPointer
        ) {
        case .collapse: collapse()
        case .postpone: scheduleAutoCollapse(after: 1)
        case .ignore: break
        }
    }

    // MARK: - Pointer gestures and hotkeys

    private func configureMonitor() {
        var options = MenuBarEventMonitor.Options()
        options.clickEmptyBar = settings.reveal.clickEmptyBar
        options.hover = settings.reveal.hover
        options.hoverDelay = settings.reveal.hoverDelay
        options.scroll = settings.reveal.scroll
        options.clicksOutside = settings.autoCollapse.enabled && settings.autoCollapse.onClickOutside
        monitor.visibleBundleFilter = { [weak self] bundle in
            guard let self else { return true }
            // While an item's app is focused, the system shows the focus set, not the plan.
            if self.assessment.isFocusing { return self.assessment.allowedBundleIDs.contains(bundle) }
            guard let allowed = self.currentAllowed else { return true }
            return allowed.contains(bundle)
        }
        monitor.isPaused = { [weak self] in self?.isActivating ?? false }
        // Pointer gestures don't give the SnugBar Bar keyboard focus, so typing stays in the frontmost app.
        monitor.onEmptyBarClick = { [weak self] in self?.toggle(focusBar: false) }
        monitor.onHover = { [weak self] in self?.expand(focusBar: false) }
        monitor.onScroll = { [weak self] direction in
            switch direction {
            case .down: self?.expand(focusBar: false)
            case .up: self?.collapse()
            }
        }
        monitor.onClickOutside = { [weak self] in
            guard let self else { return }
            // Let the click land first: if it opened or closed a menu, the window list reflects it a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if AutoCollapsePolicy.onClickOutside(state: self.state, settings: self.settings.autoCollapse, menuOpen: self.revealedMenuOpen()) {
                    self.collapse()
                }
            }
        }
        monitor.apply(options)
    }

    private func applyHotkeys() {
        hotkeys.apply(settings.hotkeys)
        hotkeyFailures = hotkeys.failures.map { "\($0.hotkey) is in use by another app" }
    }

    // MARK: - System events

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(bundle) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            // A new app under the default section must be named in the allow-list to be let through.
            MainActor.assumeIsolated {
                self?.reapplyIfHiding()
                self?.scheduleFitCheck(after: 2)
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appQuit(bundle) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyIfHiding()
                self?.scheduleFitCheck(after: 2)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyIfHiding()
                self?.scheduleFitCheck(after: 1)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        })
    }

    private func appActivated(_ bundleID: String?) {
        if AutoCollapsePolicy.onAppActivated(
            bundleID: bundleID, state: state, settings: settings.autoCollapse,
            revealedBundleIDs: revealedBundleIDs, ownBundleID: ownBundleID
        ) {
            collapse()
        }
        // Without a notch the frontmost app's menus decide how much room is left, so check the fit again.
        if lastFit?.space?.hasNotch == false, settings.moveItemsThatDontFit { scheduleFitCheck(after: 0.5) }
    }

    private func appQuit(_ bundleID: String?) {
        if let bundleID {
            measurements.forget(bundleID)
            catalog.forget(bundleID)
        }
        // An app that had to move out may fit now.
        scheduleFitCheck(after: 1)
    }

    private func reapplyIfHiding() {
        guard activeHider != nil else { return }
        applyVisibility(force: true)
    }

    /// Records the apps whose items are visible now.
    func noteVisibleApps() {
        guard Permissions.accessibility else { return }
        let items = snapshotItems()
        var visible: [String: String] = [:]
        for item in items where !item.isAppleItem && !item.ownerBundleID.isEmpty && item.ownerBundleID != ownBundleID {
            visible[item.ownerBundleID] = item.appName
        }
        visibleApps = visible
        var next = settings
        if next.noteApps(visible.map { (bundleID: $0.key, name: $0.value) }) {
            settings = next
            if !loadFailed { scheduleSave() }
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            do {
                try self.store.save(self.settings)
            } catch {
                self.lastError = "Settings not saved: \(error.localizedDescription)"
            }
        }
    }
}

extension Notification.Name {
    static let snugBarIconVisibilityChanged = Notification.Name("SnugBarIconVisibilityChanged")
}
