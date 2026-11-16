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
    /// Screen Recording as last checked: allowed, not allowed, or allowed but needing a restart. This process's own
    /// preflight goes stale, so it is only the starting point (`refreshScreenRecording`).
    @Published private(set) var screenRecording = ScreenRecordingAccess(preflight: Permissions.screenRecordingInProcess)
    @Published private(set) var orderFileGranted = false
    @Published private(set) var loginItemEnabled = LoginItem.isEnabled
    @Published private(set) var loginItemNeedsApproval = LoginItem.needsApproval
    @Published private(set) var hotkeyFailures: [String] = []
    /// Apps currently visible in the menu bar (from the last snapshot), for the Sections list.
    @Published private(set) var visibleApps: [String: String] = [:]
    /// Shown apps moved out of the menu bar because they don't fit beside the notch (features 17–18). Runtime only.
    @Published private(set) var overflowHidden: Set<String> = []
    /// "New: <App> was put in Hidden" entries for the menu (feature 41). Runtime only.
    @Published var newAppNotices = NewAppNotices()
    /// A one-line result of the last layout action (editor, restore, reset, import), for the editor and Settings.
    @Published var layoutMessage: String?
    /// Bumped when the layout should be read again (an order write settled, a ⌘-drag was adopted).
    @Published private(set) var layoutRevision = 0
    /// Opens the layout editor window (set by the app delegate).
    var openLayoutEditor: (() -> Void)?
    /// Opens the setup window, on a page when given (set by the app delegate).
    var openSetup: ((SetupStep?) -> Void)?
    /// Checks Accessibility every few seconds so a grant or a revoke takes effect without a relaunch.
    private var permissionTimer: Timer?

    let ownBundleID = Bundle.main.bundleIdentifier ?? "app.snugbar.SnugBar"
    /// SnugBar's icon in AppKit screen coordinates, when it is shown. Set by the status item.
    var iconFrame: (() -> NSRect?)?

    let reader = MenuBarReader()
    private let assessment = AssessmentHider()
    private let divider = OverflowDividerHider()
    let orderFile = OrderFileAccess()
    private let hotkeys = HotkeyCenter()
    private lazy var notificationGuard = NotificationCenterGuard(hider: assessment, reader: reader)
    private lazy var monitor = MenuBarEventMonitor(reader: reader)
    private lazy var activator = makeActivator()
    let imager = ItemImager(cacheDirectory: ItemImager.defaultCacheDirectory)
    private let bar = SnugBarBarController()
    private let search = SearchPanelController()
    let store = SettingsStore(url: SettingsStore.defaultURL)
    private var activeHider: Hider?
    /// Bundle IDs allowed by the current plan, or nil when nothing is hidden.
    private(set) var currentAllowed: Set<String>?
    private var collapseTimer: Timer?
    private var barRefreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var saveScheduled = false
    /// Items seen while visible, so hidden apps can be listed and searched.
    var catalog = ItemCatalog()
    /// Widths of shown apps, kept while SnugBar has moved them out.
    private var measurements = FitMeasurements()
    private(set) var lastFit: FitAnalysis?
    private var fitWork: DispatchWorkItem?
    /// Moves the leftmost shown app out when macOS's overflow shows though the plan says everything fits.
    private var safetyNet = FitSafetyNet()
    /// The last snapshot had macOS's « button.
    private var lastSnapshotHadOverflowIndicator = false
    private var lastSafetyNetLog: String?
    private var captureInFlight = false
    /// When items may be captured: only once they've settled after the bar changed (SPEC 3.5).
    var captureGate = CaptureSettleGate()
    /// After a ⌘-drag in the menu bar ends, until the bar has settled and its order was read.
    var postDragSettling = false
    /// A hider update asked for while the bar was frozen (the value: whether it was forced).
    private var deferredVisibility: Bool?
    private var deferredSpacerSync = false
    /// An item is being opened (focus, synthetic click, pointer put back); reveal gestures are ignored until shortly
    /// after, so nothing SnugBar does on the user's behalf reopens the SnugBar Bar over the item's menu.
    private var activationsInFlight = 0
    private var gesturesQuietUntil = Date.distantPast
    /// The settings file exists but couldn't be read: only an explicit change by the user may replace it.
    var loadFailed = false
    /// Apps shown on their own by the `show` command, and when they hide again.
    private var appRevealTimers: [String: Timer] = [:]
    lazy var arranger = Arranger(reader: reader, access: orderFile)
    let spacerBar = SpacerBar()
    let dragWatcher = CommandDragWatcher()
    lazy var keeper = LayoutKeeper(controller: self)

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

    /// A controller that only backs an offscreen Settings render (`--debug settings-snapshot`): it uses `settings`,
    /// never reads or writes the settings file or the order file, and is never started.
    init(preview settings: Settings, grants: PermissionGrants = .all) {
        self.settings = settings
        isPreview = true
        accessibilityGranted = grants.accessibility
        screenRecording = ScreenRecordingAccess(state: grants.screenRecording ? .granted : .notGranted)
        orderFileGranted = grants.orderFile
        loginItemEnabled = false
        loginItemNeedsApproval = false
    }

    private(set) var isPreview = false

    // MARK: - Lifecycle

    func start() {
        noteVisibleApps()
        hotkeys.onPress = { [weak self] action in self?.perform(action) }
        applyHotkeys()
        configureMonitor()
        configurePanels()
        observeSystem()
        if preferredHider().backend == .overflowDivider { divider.install() }
        assessment.onChange = { [weak self] in self?.noteBarChanged() }
        applyVisibility()
        scheduleFitCheck(after: 1.5)
        startLayout()
        startPermissionTimer()
    }

    /// Stops hiding so the bar is whole when SnugBar quits (the system would also end the hide on exit).
    func stop() {
        collapseTimer?.invalidate()
        barRefreshTimer?.invalidate()
        permissionTimer?.invalidate()
        appRevealTimers.values.forEach { $0.invalidate() }
        appRevealTimers = [:]
        bar.dismiss()
        search.dismiss()
        notificationGuard.stop()
        monitor.stop()
        keeper.stop()
        dragWatcher.stop()
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

    /// A click on SnugBar's icon. With the search palette open it only closes search (the press already took focus
    /// from it, which closes it, so that is remembered for this click); otherwise it toggles, which also closes an
    /// open SnugBar Bar (the bar ignores presses on the icon, so the click isn't undone by a click-outside first).
    func iconClicked() {
        if search.takeIconPressDismissal() || search.isVisible {
            search.dismiss()
            return
        }
        toggle()
    }

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
        // Without Accessibility there is no SnugBar Bar: hidden items show in the menu bar (feature 87).
        let inBar = level != .collapsed && (letters || settings.revealIn == .snugBarBar) && checkAvailable(.snugBarBar)
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
        // Zen takes SnugBar's spacers out of the menu bar (remembering their places); its end puts them back.
        syncSpacers()
        if !on {
            scheduleFitCheck(after: 1.5)
            // Puts back anything that lost its place while Zen hid it.
            keeper.trigger(.zenEnded, after: 1.5)
        }
    }

    // MARK: - SnugBar Bar, search and open by letter (features 16, 20–28)

    /// Opens the SnugBar Bar with a key on each item; typing a key opens that item.
    func openByLetter() {
        guard !state.zen, checkAvailable(.openByLetter) else { return }
        search.dismiss()
        if state.reveal == .collapsed || !state.revealInBar || !bar.isVisible {
            setReveal(state.reveal == .collapsed ? .expanded : state.reveal, letters: true)
        } else {
            showBar(letters: true, focus: true)
        }
    }

    func showSearch() {
        guard !state.zen, checkAvailable(.search) else { return }
        if state.revealInBar && state.reveal != .collapsed { collapse() }
        search.show()
    }

    /// Opens an item's menu (ItemActivator: focus it if hidden, then click it) and remembers it as recent.
    ///
    /// The SnugBar Bar and the search palette are ordered out first, before anything is focused or clicked, and stay
    /// closed: the item's menu must be the only thing on screen.
    func activate(_ item: MenuBarItem) {
        guard !state.zen, checkAvailable(.openItems) else { return }
        let positions = prepareActivation(item)
        Task { @MainActor in
            defer { self.finishActivation() }
            do {
                _ = try await self.activator.activate(item, orderPositions: positions)
            } catch {
                NSLog("SnugBar: could not open %@: %@", item.id.rawValue, String(describing: error))
                NSSound.beep()
            }
        }
    }

    /// Opens an item's menu like `activate`, and reports how (or why it couldn't). Used by the `click` command.
    func open(_ item: MenuBarItem) async throws -> ItemActivator.Result {
        let positions = prepareActivation(item)
        defer { finishActivation() }
        return try await activator.activate(item, orderPositions: positions)
    }

    /// Closes SnugBar's panels before an item is focused or clicked, and remembers the item as recent.
    private func prepareActivation(_ item: MenuBarItem) -> [String: Double]? {
        bar.dismiss()
        search.dismiss()
        barRefreshTimer?.invalidate()
        activationsInFlight += 1
        if state.revealInBar && state.reveal != .collapsed { collapse() }
        update { $0.noteRecent(item.id) }
        return try? orderFile.readPositions()
    }

    private func finishActivation() {
        activationsInFlight -= 1
        // The synthetic click's mouse-up and the pointer warp land a moment later.
        gesturesQuietUntil = Date().addingTimeInterval(0.6)
    }

    /// True while an item is being opened, and briefly after.
    private var isActivating: Bool { activationsInFlight > 0 || Date() < gesturesQuietUntil }

    /// The menu bar doesn't show the plan right now (an item is being opened, or the hide is lifted for Notification
    /// Center): layout checks wait.
    var layoutIsBusy: Bool { isActivating || assessment.isFocusing || assessment.isSuspended }

    func bumpLayoutRevision() { layoutRevision &+= 1 }

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
            let positions = try? self.orderFile.readPositions()
            guard !self.imager.hasCachedImage(for: item.id, orderPositions: positions),
                  self.screenRecording.isUsable else { return }
            do {
                _ = try await self.imager.refresh(visibleItems, preflight: false) { [reader = self.reader] in
                    reader.currentFrames(orderPositions: positions)
                }
            } catch {
                self.noteCaptureFailed(error)
            }
        }
        return activator
    }

    private func configurePanels() {
        bar.onActivate = { [weak self] item in self?.activate(item) }
        bar.onDismiss = { [weak self] in
            guard let self, self.state.revealInBar, self.state.reveal != .collapsed else { return }
            self.collapse()
        }
        bar.ownIconFrame = { [weak self] in self?.iconFrame?() }
        bar.onDrop = { [weak self] request in self?.barDropped(request) }
        // No reconcile while a tile is dragged in the bar, as in the layout editor.
        bar.onDragging = { [weak self] dragging in self?.keeper.editorDragging = dragging }
        search.ownIconFrame = { [weak self] in self?.iconFrame?() }
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
            NSImage.forBarItem(self?.itemImage(for: item, positions: try? self?.orderFile.readPositions()))
        }
        search.onActivate = { [weak self] item in self?.activate(item) }
    }

    private func barGroups(letters: Bool) -> [SnugBarBarController.Group] {
        let positions = try? orderFile.readPositions()
        // Hidden items in the order they take when their section is expanded.
        let items = SectionOrder.arranged(allItems(), sections: settings.sections, layout: settings.layout, positions: positions)
        let groups = BarListing.groups(
            items: items, sections: settings.sections, state: state, overflowHidden: effectiveOverflow, excluding: [ownBundleID]
        )
        var images: [ItemID: ItemImager.ItemImage] = [:]
        for item in groups.flatMap(\.items) { images[item.id] = itemImage(for: item, positions: positions) }
        // An app's items without a picture of their own would all show its icon: they share one tile.
        let tiled = groups.map { group in
            (group.kind, BarListing.tiles(for: group.items) { item in
                images[item.id].map { $0.source != .appIcon } ?? false
            })
        }
        let keys = letters ? LetterAssigner.assign(tiled.flatMap { $0.1.map(\.item) }) : [:]
        // Tiles can be dragged to reorder only with the order file, which is what places hidden items (SPEC 3.4).
        let swapped = state.swapped
        return tiled.map { kind, tiles in
            SnugBarBarController.Group(kind: kind, entries: tiles.map { tile in
                .init(tile: tile, image: NSImage.forBarItem(images[tile.id]), key: keys[tile.id],
                      canDrag: BarDrag.canDrag(tile, in: kind, swapped: swapped, positions: positions))
            }, section: BarDrag.section(of: kind, swapped: swapped))
        }
    }

    /// A tile dropped in the SnugBar Bar: written like a drop in the layout editor (desired order, order file through
    /// the keeper), then the rows show the new order at once from the desired layout. Pictures stay cached: the order
    /// write marks the bar as changing, so nothing is captured until items settle.
    private func barDropped(_ request: SnugBarBarController.DropRequest) {
        let positions = try? orderFile.readPositions()
        switch BarDrag.outcome(dragging: request.tile, from: request.from, onto: request.onto, gap: request.gap,
                               row: request.row, positions: positions) {
        case let .reorder(section, order, appsIn):
            editorReorder(section, order: order, appsIn: appsIn)
            noteBarChanged()
            if bar.isVisible, !bar.isShowingKeys { bar.update(groups: barGroups(letters: false)) }
        case .none, .notAllowed:
            break
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
                // Not mid-drag: the rows stay put until the drop.
                guard !self.bar.isDragging else { return }
                self.bar.update(groups: self.barGroups(letters: false))
            }
        }
    }

    /// The picture for an item: captured or cached with Screen Recording, the app icon without it (feature 86).
    func itemImage(for item: MenuBarItem, positions: [String: Double]?) -> ItemImager.ItemImage? {
        imager.image(for: item, orderPositions: positions, iconsOnly: !availability.showsItemPictures)
    }

    /// How long a capture waits at most for items to settle; items still moving after that keep their old pictures.
    nonisolated static let captureSettleTimeout: TimeInterval = 3

    /// Captures pictures of the items on screen now (needs Screen Recording). Hidden items can't be captured, so
    /// this runs when items are visible: after a reveal in the menu bar, and before apps move to "Didn't fit".
    ///
    /// An item is captured only once it has settled (`CaptureSettleGate`): its frame was the same on two reads at
    /// least 0.3 s apart and the bar last changed at least 0.8 s ago. Until then it keeps its last good picture; the
    /// frames are read again until every item settled or `captureSettleTimeout` passed. Nothing is captured while the
    /// user ⌘-drags items.
    func captureVisibleItems(then done: (() -> Void)? = nil) {
        guard screenRecording.systemGranted, Permissions.accessibility, !captureInFlight, !barIsFrozen,
              !assessment.isFocusing, !assessment.isSuspended
        else { done?(); return }
        captureInFlight = true
        Task { @MainActor in
            // Revoked or granted since the last look: this process's own preflight can't tell (feature 86).
            await self.refreshScreenRecording()
            guard self.screenRecording.isUsable else {
                self.captureInFlight = false
                done?()
                return
            }
            var tried = Set<ItemID>()
            let deadline = Date().addingTimeInterval(Self.captureSettleTimeout)
            while !self.barIsFrozen, !self.assessment.isFocusing, !self.assessment.isSuspended {
                let positions = try? self.orderFile.readPositions()
                let items = self.capturableItems(positions: positions)
                let now = Date()
                self.captureGate.record(Self.gateFrames(items), at: now)
                let (ready, readAgainAt) = self.captureGate.split(items.map(\.id.rawValue), at: now)
                let readyKeys = Set(ready)
                let batch = items.filter { readyKeys.contains($0.id.rawValue) && !tried.contains($0.id) }
                if !batch.isEmpty {
                    tried.formUnion(batch.map(\.id))
                    do {
                        // The batch is on screen and not overflowed, so the strip was captured.
                        _ = try await self.imager.refresh(batch, preflight: false) { [reader = self.reader] in
                            reader.currentFrames(orderPositions: positions)
                        }
                        self.screenRecording.noteCapture(.succeeded)
                    } catch {
                        self.noteCaptureFailed(error)
                        if !self.screenRecording.isUsable { break }
                    }
                }
                guard let next = readAgainAt, next < deadline else { break }
                try? await Task.sleep(nanoseconds: UInt64(max(next.timeIntervalSinceNow, 0.05) * 1_000_000_000))
            }
            self.captureInFlight = false
            done?()
        }
    }

    /// Items on screen in the menu bar now (Apple's and allowed apps'), not in macOS's overflow.
    private func capturableItems(positions: [String: Double]?) -> [MenuBarItem] {
        let onScreen = currentAllowed
        return reader.snapshot(orderPositions: positions).items.filter { item in
            !item.isOverflowed && item.frame.width > 0 && (item.isAppleItem || onScreen?.contains(item.ownerBundleID) ?? true)
        }
    }

    private static func gateFrames(_ items: [MenuBarItem]) -> [String: Rect] {
        Dictionary(items.map { ($0.id.rawValue, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    /// Something SnugBar did is moving items now (allow-list, order file, spacers, a ⌘-drag ended).
    func noteBarChanged() {
        captureGate.noteBarChange(at: Date())
    }

    /// Reads the menu bar until every item on screen has settled (same rule as captures), or `timeout` passes.
    func waitForBarToSettle(timeout: TimeInterval = captureSettleTimeout) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let items = capturableItems(positions: try? orderFile.readPositions())
            let now = Date()
            captureGate.record(Self.gateFrames(items), at: now)
            guard let next = captureGate.split(items.map(\.id.rawValue), at: now).readAgainAt, next < deadline else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(next.timeIntervalSinceNow, 0.05) * 1_000_000_000))
            if Task.isCancelled { return }
        }
    }

    // MARK: - ⌘-drag in the menu bar

    /// The user is ⌘-dragging items in the menu bar, or it hasn't settled since: SnugBar changes nothing in the bar
    /// (no hider update, no spacer change, no order write) and captures nothing. Hider and spacer updates asked for
    /// meanwhile run once it is over (`barUnfrozen`).
    var barIsFrozen: Bool { !isPreview && (dragWatcher.userIsDragging || postDragSettling) }

    /// The drag is over and the bar settled: catch up on what was held back.
    func barUnfrozen() {
        guard !barIsFrozen else { return }
        if let force = deferredVisibility {
            deferredVisibility = nil
            applyVisibility(force: force)
        }
        if deferredSpacerSync {
            deferredSpacerSync = false
            syncSpacers()
        }
    }

    func deferSpacerSync() { deferredSpacerSync = true }

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
        // Measure only the collapsed menu bar, and not while an item is being opened, the hide is lifted or the user
        // ⌘-drags items.
        if state.menuBarReveal != .collapsed { return }
        if assessment.isFocusing || assessment.isSuspended || barIsFrozen || isActivating {
            scheduleFitCheck(after: 2)
            return
        }
        let live = snapshotItems()
        let shown = VisibilityPlanner.collapsedVisibleApps(
            state: state, sections: settings.sections,
            candidates: ItemGathering.appsWithItems(live: live, measurements: measurements, remembered: Set(catalog.itemsByApp.keys),
                                                    running: ItemGathering.runningBundleIDs(), ownBundleID: ownBundleID),
            excluding: [ownBundleID]
        )
        let onScreen = currentAllowed
        var analysis = FitAnalysis.make(
            items: live, measurements: measurements, remembered: catalog.itemsByApp, shownApps: shown, ownBundleID: ownBundleID,
            isOnScreen: { onScreen?.contains($0) ?? true }, movedNow: overflowHidden,
            overflowIndicator: lastSnapshotHadOverflowIndicator, shortfall: { [self] in safetyNet.shortfall(for: $0) }
        )
        guard let plan = analysis.plan else {
            lastFit = analysis
            return
        }
        var next = Set(plan.moved)
        // The safety net: macOS's overflow in use while the plan says everything fits.
        let settledSince = captureGate.lastBarChange.map { Date().timeIntervalSince($0) } ?? .infinity
        let verdict = safetyNet.decide(
            survey: analysis.check.survey, plan: plan, movedNow: overflowHidden,
            settled: settledSince >= FitSafetyNet.settleTime, userBusy: barIsFrozen || isActivating, now: Date()
        )
        analysis.safetyNet = verdict.label
        lastFit = analysis
        switch verdict {
        case let .fire(app):
            next.insert(app)
            NSLog("SnugBar: macOS's overflow is in use though the estimate fits (%@); moving %@ to Didn't Fit, learnt shortfall %.1f pt",
                  analysis.check.survey.overflowedApps.joined(separator: ", "), app, safetyNet.shortfall)
        case .settling:
            scheduleFitCheck(after: max(FitSafetyNet.settleTime - settledSince, 0) + 0.3)
        case .roundLimit, .nothingToMove:
            if lastSafetyNetLog != verdict.label { NSLog("SnugBar: fit safety net %@", verdict.label) }
        case .quiet, .planMoves, .userBusy:
            break
        }
        lastSafetyNetLog = verdict.label
        guard next != overflowHidden else { return }
        let newlyMoved = next.subtracting(overflowHidden)
        let apply = { [weak self] in
            guard let self else { return }
            self.overflowHidden = next
            self.noteBarChanged()
            self.applyVisibility()
            if self.bar.isVisible, !self.bar.isShowingKeys { self.bar.update(groups: self.barGroups(letters: false)) }
            // Check again once the bar has settled: macOS may still overflow (the safety net then moves the next app).
            self.scheduleFitCheck(after: FitSafetyNet.settleTime + 0.5)
        }
        // Keep pictures of apps about to leave the menu bar while they are still on screen.
        let positions = try? orderFile.readPositions()
        let needsCapture = live.contains {
            newlyMoved.contains($0.ownerBundleID) && !$0.isOverflowed && !imager.hasCachedImage(for: $0.id, orderPositions: positions)
        }
        if needsCapture { captureVisibleItems(then: apply) } else { apply() }
    }

    /// One snapshot, also used to remember items and widths of apps that are on screen.
    func snapshotItems() -> [MenuBarItem] {
        let snap = reader.snapshot(orderPositions: try? orderFile.readPositions())
        let items = snap.items
        lastSnapshotHadOverflowIndicator = snap.overflowIndicatorFrame != nil
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

    // MARK: - Control surface (CLI, MCP, URL scheme)

    /// Every item SnugBar knows, without its own, and whether each is on screen in the menu bar now.
    func controlItems() -> [ControlEngineItem] {
        let live = Permissions.accessibility ? snapshotItems() : []
        let liveIDs = Set(live.map(\.id))
        let items = catalog.merged(live: live, running: ItemGathering.runningBundleIDs(), knownApps: settings.knownApps)
            .filter { $0.ownerBundleID != ownBundleID }
        // While hiding (or focusing an item), only allowed apps are on screen; otherwise everything is.
        let allowed: Set<String>? = assessment.isFocusing || (activeHider === assessment && !assessment.isSuspended)
            ? assessment.allowedBundleIDs : nil
        return items.map { item in
            let onScreen = liveIDs.contains(item.id) && !item.isOverflowed
                && (item.isAppleItem || allowed?.contains(item.ownerBundleID) ?? true)
            return ControlEngineItem(item: item, visible: onScreen)
        }
    }

    /// One app can be shown on its own only with the per-app hider.
    var canRevealSingleApp: Bool { preferredHider() === assessment && assessment.isAvailable }

    /// Shows one app's items until the auto-hide delay passes (later while one of its menus is open).
    func revealApp(_ bundleID: String) {
        assessment.allowTemporarily(bundleID)
        scheduleAppRehide(bundleID, after: settings.autoCollapse.delay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.noteVisibleApps() }
    }

    /// Ends a reveal of one app now. When the app is still on screen because its whole section is revealed in the
    /// menu bar, the menu bar collapses.
    func hideApp(_ bundleID: String) {
        appRevealTimers.removeValue(forKey: bundleID)?.invalidate()
        assessment.endTemporaryAllowance(bundleID)
        let section = settings.sections.section(forBundleID: bundleID)
        if state.visibleSections.contains(section), !state.collapsedSections.contains(section) { collapse() }
    }

    private func scheduleAppRehide(_ bundleID: String, after delay: TimeInterval) {
        appRevealTimers.removeValue(forKey: bundleID)?.invalidate()
        appRevealTimers[bundleID] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pids = Set(NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }.map(\.processIdentifier))
                if OpenMenuDetector.isMenuOpenNow(ownerPIDs: pids) {
                    self.scheduleAppRehide(bundleID, after: 1)
                } else {
                    self.appRevealTimers.removeValue(forKey: bundleID)
                    self.assessment.endTemporaryAllowance(bundleID)
                }
            }
        }
    }

    /// How `order` moves items now: the order file when access is granted, else ⌘-drag. Either way the items are
    /// found by reading the menu bar, so nothing without Accessibility.
    var controlArranger: ControlArranger? {
        guard Permissions.accessibility else { return nil }
        return hasOrderFileAccess ? .orderFile : .drag
    }

    var hasOrderFileAccess: Bool { orderFileGranted || orderFile.status == .granted }

    /// Moves a shown item next to another with the Arranger (order file, or the ⌘-drag fallback).
    func order(_ item: MenuBarItem, _ placement: ControlPlacement) async throws -> ControlArranger {
        let p: Arranger.Placement
        switch placement {
        case let .before(anchor): p = .before(anchor)
        case let .after(anchor): p = .after(anchor)
        }
        let result = try await arranger.move(item, p)
        noteUserOrder(item, placement)
        return result.method == .orderFile ? .orderFile : .drag
    }

    var hiderBackendName: String { preferredHider().backend.rawValue }

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
        if next.layout.spacers != before.layout.spacers { syncSpacers() }
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

    /// Moves one or more apps at once: one settings change, so one save and one hider update.
    func setSection(_ section: Section, for bundleIDs: [String]) {
        update { $0.sections.set(section, forBundleIDs: bundleIDs) }
        newAppNotices.appsMoved(bundleIDs)
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

    /// What works with the permissions as last checked (features 86, 87).
    var availability: FeatureAvailability {
        FeatureAvailability(accessibility: accessibilityGranted, screenRecording: screenRecording.isUsable, orderFile: orderFileGranted)
    }

    /// The permissions Settings > Permissions and the setup window show as allowed. Screen Recording counts once
    /// System Settings allows it, even while this process needs a restart to use it: the restart line says so, and
    /// the button to System Settings would send the user to a switch that is already on.
    var shownGrants: PermissionGrants {
        var grants = availability.grants
        grants.screenRecording = screenRecording.systemGranted
        return grants
    }

    /// Re-reads every permission and applies a change of Accessibility at once (no relaunch). Called on activation,
    /// when the menu opens, when the setup or Settings window appears, every second while the setup window or the
    /// Permissions pane is open, and by the Accessibility timer. Screen Recording's fresh check runs in the
    /// background, at most every 2 s.
    func refreshPermissions() {
        guard !isPreview else { return }
        let hadAccessibility = accessibilityGranted
        accessibilityGranted = Permissions.accessibility
        orderFileGranted = orderFile.status == .granted
        refreshLoginItem()
        if accessibilityGranted != hadAccessibility { accessibilityChanged() }
        Task { await self.refreshScreenRecording() }
    }

    private var screenRecordingCheck: Task<Void, Never>?

    /// Asks a fresh process whether Screen Recording is allowed (this process's own answer goes stale), at most
    /// every `ScreenRecordingAccess.checkInterval` unless forced or a capture was just refused; when the system allows
    /// it but this process's capture isn't known to work, probes it. A check already running is waited for.
    @discardableResult
    func refreshScreenRecording(force: Bool = false) async -> ScreenRecordingState {
        guard !isPreview else { return screenRecording.state }
        if let running = screenRecordingCheck {
            await running.value
            return screenRecording.state
        }
        let now = Date()
        guard force || screenRecording.checkIsDue(at: now) else { return screenRecording.state }
        screenRecording.noteCheckStarted(at: now)
        let check = Task { @MainActor in
            // Without the bundled helper (an unbundled build) this process's answer is the best there is.
            let granted = await Permissions.freshScreenRecording() ?? Permissions.screenRecordingInProcess
            self.screenRecording.noteSystemCheck(granted: granted)
            if self.screenRecording.needsProbe {
                self.screenRecording.noteProbe(await Permissions.probeScreenCapture())
            }
        }
        screenRecordingCheck = check
        await check.value
        screenRecordingCheck = nil
        return screenRecording.state
    }

    /// A capture failed: refused for permission turns pictures off now (app icons) and makes the next check due.
    private func noteCaptureFailed(_ error: Error) {
        guard ItemImager.isPermissionError(error) else { return }
        screenRecording.noteCapture(.refused)
        NSLog("SnugBar: screen capture refused for lack of permission; showing app icons")
        Task { await self.refreshScreenRecording() }
    }

    /// For `--debug setup-snapshot --restart-hint`: allowed in System Settings, but this process can't capture yet.
    func previewRestartHint() {
        guard isPreview else { return }
        screenRecording = ScreenRecordingAccess(state: .grantedNeedsRestart)
    }

    /// SnugBar became active again: the user may be back from System Settings.
    func noteReturnedToApp() {
        guard !isPreview else { return }
        refreshPermissions()
    }

    /// Whether a feature can be used now. Re-checks Accessibility first (one cheap call), so a revoke is noticed the
    /// moment a feature that needs it is asked for.
    @discardableResult
    func checkAvailable(_ feature: AppFeature) -> Bool {
        if !isPreview, feature.requirements.contains(.accessibility), Permissions.accessibility != accessibilityGranted {
            refreshPermissions()
        }
        return availability.isAvailable(feature)
    }

    /// Accessibility is the only permission that can't be watched cheaply from its effects, and there is no
    /// notification for changes. `AXIsProcessTrusted` is a cheap local check, so it runs every 5 s; a change runs a
    /// full refresh. This picks up a grant made outside the setup window and a revoke while SnugBar is in the
    /// background.
    private func startPermissionTimer() {
        permissionTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Permissions.accessibility != self.accessibilityGranted else { return }
                self.refreshPermissions()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    /// Full mode starts or ends: gestures, the Notification Center guard, panels, the fit check and the layout keeper
    /// follow the new state. Granted: learn the menu bar and re-apply everything. Revoked: close the reader-driven
    /// panels and fall back to basic hide and show; nothing that needs the reader keeps running.
    private func accessibilityChanged() {
        configureMonitor()
        if accessibilityGranted {
            noteVisibleApps()
            applyVisibility(force: true)
            scheduleFitCheck(after: 1.5)
            keeper.trigger(.launch, after: 2)
        } else {
            bar.dismiss()
            search.dismiss()
            barRefreshTimer?.invalidate()
            notificationGuard.stop()
            if state.revealInBar {
                state.revealInBar = false
                state.reveal = .collapsed
            }
            overflowHidden = []
            applyVisibility(force: activeHider != nil)
        }
    }

    // MARK: - Setup (feature 85)

    /// Applies the launch decision: stores the migrated value and says whether to show the setup window.
    func setupShouldShowAtLaunch(settingsFileExisted: Bool) -> Bool {
        let decision = SetupLaunchDecision.decide(
            setupCompleted: settings.setupCompleted, settingsFileExists: settingsFileExisted, accessibility: Permissions.accessibility
        )
        if let value = decision.store { setSetupCompleted(value) }
        return decision.show
    }

    /// The setup window was finished or closed.
    func markSetupCompleted() { setSetupCompleted(true) }

    private func setSetupCompleted(_ value: Bool) {
        guard settings.setupCompleted != value else { return }
        if loadFailed || isPreview {
            // Never replace a settings file that couldn't be read just to remember this.
            settings.setupCompleted = value
        } else {
            update { $0.setupCompleted = value }
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
    func candidateBundleIDs() -> Set<String> {
        var result = Set(settings.knownApps.keys)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            if let id = app.bundleIdentifier { result.insert(id) }
        }
        return result
    }

    /// - Parameter force: re-apply even when the allow-list hasn't changed (after wake, display or app changes).
    func applyVisibility(force: Bool = false) {
        // Not while the user ⌘-drags items: the bar would change under the pointer. Done once the drag settles.
        if barIsFrozen {
            deferredVisibility = (deferredVisibility ?? false) || force
            return
        }
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
                // The guard reads the clock's frame from the menu bar, which needs Accessibility.
                if hider === assessment, availability.isAvailable(.notificationCenter) { notificationGuard.start() } else { notificationGuard.stop() }
                lastError = nil
            } catch {
                lastError = "\(error)"
            }
        }
    }

    private func applyDivider(hide: Bool) {
        notificationGuard.stop()
        noteBarChanged()
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
        // A collapse would change the bar under a ⌘-drag, or close the SnugBar Bar under a drag in it.
        if barIsFrozen || bar.isDragging {
            scheduleAutoCollapse(after: 1)
            return
        }
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
        // Gestures on the menu bar need the reader (an "empty" spot is one without an item); without Accessibility
        // only the click-outside watch for auto-collapse stays.
        let gestures = availability.isAvailable(.revealGestures)
        options.clickEmptyBar = gestures && settings.reveal.clickEmptyBar
        options.hover = gestures && settings.reveal.hover
        options.hoverDelay = settings.reveal.hoverDelay
        options.scroll = gestures && settings.reveal.scroll
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
                if self.bar.isDragging { return }
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
        observers.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            // A new app under the default section must be named in the allow-list to be let through.
            MainActor.assumeIsolated {
                self?.reapplyIfHiding()
                self?.scheduleFitCheck(after: 2)
                if let bundle { self?.keeper.appLaunched(bundle) }
            }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keeper.trigger(.spaceChanged) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appQuit(bundle) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyIfHiding()
                self?.scheduleFitCheck(after: 2)
                self?.keeper.trigger(.wake, after: 2)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyIfHiding()
                self?.scheduleFitCheck(after: 1)
                self?.keeper.trigger(.displayChanged, after: 1.5)
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteReturnedToApp() }
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

    func reapplyIfHiding() {
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
        noteNewApps(items, seen: visible)
        var next = settings
        if next.noteApps(visible.map { (bundleID: $0.key, name: $0.value) }) {
            settings = next
            if !loadFailed { scheduleSave() }
        }
    }

    func scheduleSave() {
        guard !saveScheduled, !isPreview else { return }
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
