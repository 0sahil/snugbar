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

    let ownBundleID = Bundle.main.bundleIdentifier ?? "app.snugbar.SnugBar"

    private let reader = MenuBarReader()
    private let assessment = AssessmentHider()
    private let divider = OverflowDividerHider()
    private let orderFile = OrderFileAccess()
    private let hotkeys = HotkeyCenter()
    private lazy var notificationGuard = NotificationCenterGuard(hider: assessment, reader: reader)
    private lazy var monitor = MenuBarEventMonitor(reader: reader)
    private let store = SettingsStore(url: SettingsStore.defaultURL)
    private var activeHider: Hider?
    /// Bundle IDs allowed by the current plan, or nil when nothing is hidden.
    private var currentAllowed: Set<String>?
    private var collapseTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var saveScheduled = false
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
        observeSystem()
        if preferredHider().backend == .overflowDivider { divider.install() }
        applyVisibility()
    }

    /// Stops hiding so the bar is whole when SnugBar quits (the system would also end the hide on exit).
    func stop() {
        collapseTimer?.invalidate()
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

    func toggle() { setReveal(state.reveal == .collapsed ? .expanded : .collapsed) }

    func toggleAlwaysHidden() { setReveal(state.reveal == .all ? .collapsed : .all) }

    func expand() { if state.reveal == .collapsed { setReveal(.expanded) } }

    func collapse() { setReveal(.collapsed) }

    func swap() {
        guard supportsSwap else { return }
        state.swapped.toggle()
        state.reveal = .collapsed
        collapseTimer?.invalidate()
        applyVisibility()
    }

    func setReveal(_ level: RevealLevel) {
        state.reveal = level
        if level == .collapsed { monitor.suppressHoverUntilPointerLeaves() }
        applyVisibility()
        scheduleAutoCollapse()
        if level != .collapsed {
            // Learn apps that just appeared (only possible while they're visible).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.noteVisibleApps() }
        }
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleHidden: toggle()
        case .toggleAlwaysHidden: toggleAlwaysHidden()
        case .swap: swap()
        }
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

    private func applyVisibility() {
        let hider = preferredHider()
        if !hider.supportsAllowList {
            // The divider hides by position: collapsed hides, any reveal shows.
            applyDivider(hide: state.reveal == .collapsed)
            return
        }
        let plan = VisibilityPlanner.plan(
            state: state, sections: settings.sections, candidates: candidateBundleIDs(), alwaysAllowed: [ownBundleID]
        )
        switch plan {
        case .showEverything:
            notificationGuard.stop()
            activeHider?.show()
            activeHider = nil
            currentAllowed = nil
            lastError = nil
        case let .allow(allowed):
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
            candidates: candidateBundleIDs(), alwaysAllowed: [ownBundleID]
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
            menuOpen: revealedMenuOpen(), pointerInMenuBar: MenuBarEventMonitor.pointerInMenuBar
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
            guard let self, let allowed = self.currentAllowed else { return true }
            return allowed.contains(bundle)
        }
        monitor.onEmptyBarClick = { [weak self] in self?.toggle() }
        monitor.onHover = { [weak self] in self?.expand() }
        monitor.onScroll = { [weak self] direction in
            switch direction {
            case .down: self?.expand()
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
            MainActor.assumeIsolated { self?.reapplyIfHiding() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyIfHiding() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyIfHiding() }
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
    }

    private func reapplyIfHiding() {
        guard activeHider != nil else { return }
        applyVisibility()
    }

    /// Records the apps whose items are visible now.
    func noteVisibleApps() {
        guard Permissions.accessibility else { return }
        let snapshot = reader.snapshot()
        var visible: [String: String] = [:]
        for item in snapshot.items where !item.isAppleItem && !item.ownerBundleID.isEmpty && item.ownerBundleID != ownBundleID {
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
