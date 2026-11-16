import AppKit
import Combine
import SnugBarCore
import SwiftUI

/// SnugBar's icon in the menu bar: a click expands or collapses the Hidden section (feature 2); a right-click,
/// ⌃-click or ⌥-click opens the menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let autosaveName = "snugbar.icon"

    private let controller: AppController
    private let updater: Updater
    private let openSettings: () -> Void
    private let openAbout: () -> Void
    private var item: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AppController, updater: Updater, openSettings: @escaping () -> Void, openAbout: @escaping () -> Void) {
        self.controller = controller
        self.updater = updater
        self.openSettings = openSettings
        self.openAbout = openAbout
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = Self.autosaveName
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("SnugBar")
        }
        self.item = item
        controller.iconFrame = { [weak self] in
            guard let item = self?.item, item.isVisible, let window = item.button?.window else { return nil }
            return window.frame
        }
        controller.$state.combineLatest(controller.$lastError)
            .sink { [weak self] state, error in self?.updateIcon(state: state, hasError: error != nil) }
            .store(in: &cancellables)
        controller.$settings.map(\.showIcon).removeDuplicates()
            .sink { [weak self] show in self?.item?.isVisible = show }
            .store(in: &cancellables)
        controller.$accessibilityGranted.removeDuplicates()
            .sink { [weak self] _ in self?.updateIcon(state: controller.state, hasError: controller.lastError != nil) }
            .store(in: &cancellables)
        // The style changes live. `$settings` publishes before the value is stored, so read it on the next turn.
        controller.$settings.map(\.menuBarIcon).removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateIcon(state: controller.state, hasError: controller.lastError != nil) }
            }
            .store(in: &cancellables)
    }

    private func updateIcon(state: BarState, hasError: Bool) {
        let iconState = MenuBarIconState.resolve(state, accessibilityGranted: controller.accessibilityGranted, hasError: hasError)
        item?.button?.image = MenuBarIconRenderer.image(controller.settings.menuBarIcon, iconState)
        if !controller.accessibilityGranted {
            item?.button?.toolTip = PermissionText.iconTooltipReduced
        } else if state.zen {
            item?.button?.toolTip = "SnugBar: Zen mode is on. Click for the menu."
        } else {
            item?.button?.toolTip = state.reveal == .collapsed ? "SnugBar: click to show hidden items" : "SnugBar: click to hide items"
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control) || event.modifierFlags.contains(.option)
        // In Zen nothing can be revealed, so a click offers the menu (and the way out of Zen).
        if wantsMenu || controller.state.zen {
            showMenu()
        } else {
            controller.iconClicked()
        }
    }

    private func showMenu() {
        guard let item, let button = item.button else { return }
        controller.refreshPermissions()
        let menu = buildMenu()
        // Attach temporarily so the menu opens under the icon in the system style, then detach so clicks toggle again.
        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    private func buildMenu() -> NSMenu {
        StatusMenu.build(controller: controller, updater: updater, openSettings: openSettings, openAbout: openAbout)
    }
}

/// SnugBar's menu (right-click on the icon). Built fresh each time it opens, from the controller's state; also built
/// on its own for `--debug menu-snapshot`.
@MainActor
enum StatusMenu {
    static func build(controller c: AppController, updater: Updater, openSettings: @escaping () -> Void,
                      openAbout: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        // Enabled states are set here (Zen, permissions); automatic validation would enable every closure item.
        menu.autoenablesItems = false
        let state = c.state
        let availability = c.availability

        // An update a scheduled check found, waiting quietly until the user chooses it.
        if let version = updater.pendingUpdateVersion {
            menu.addItem(entry("Update Available: \(version)…") { updater.checkForUpdates() })
            menu.addItem(.separator())
        }

        // Reduced mode (feature 87): the way to full mode comes first.
        if !availability.grants.accessibility {
            menu.addItem(entry(PermissionText.accessibilityNeededMenuTitle) { c.openSetup?(.accessibility) })
            menu.addItem(.separator())
        }

        let show = entry(state.reveal == .collapsed ? "Show Hidden Items" : "Hide Items", key: hotkeyHint(c, .toggleHidden)) { c.toggle() }
        show.isEnabled = !state.zen
        menu.addItem(show)
        let always = entry(state.reveal == .all ? "Hide Always Hidden Items" : "Show Always Hidden Items", key: hotkeyHint(c, .toggleAlwaysHidden)) {
            c.toggleAlwaysHidden()
        }
        always.isEnabled = !state.zen
        menu.addItem(always)
        let swap = entry("Swap Shown and Hidden", key: hotkeyHint(c, .swap)) { c.swap() }
        swap.state = state.swapped ? .on : .off
        swap.isEnabled = c.supportsSwap && !state.zen
        menu.addItem(swap)
        // After the menu has closed, so the palette can take keyboard focus.
        let search = entry("Search…", key: hotkeyHint(c, .search)) { DispatchQueue.main.async { c.showSearch() } }
        needs(search, .search, availability, enabled: !state.zen)
        menu.addItem(search)
        let zen = entry("Zen Mode", key: hotkeyHint(c, .zen)) { c.toggleZen() }
        zen.state = state.zen ? .on : .off
        menu.addItem(zen)

        // Apps seen for the first time (feature 41): each notice shows once; choosing it opens the layout editor.
        let notices = c.takeNewAppNotices()
        if !notices.isEmpty {
            menu.addItem(.separator())
            for notice in notices {
                menu.addItem(entry(NewAppNotices.title(for: notice)) { c.openLayoutEditor?() })
            }
        }

        menu.addItem(.separator())
        menu.addItem(info(c.backendDescription))
        if !c.isRunningFromApplications {
            menu.addItem(info("Move SnugBar to Applications: its icon is hidden with other apps when it runs from elsewhere."))
        }
        if let error = c.lastError {
            menu.addItem(info(error))
        }

        menu.addItem(.separator())
        let layout = entry("Edit Layout…") { c.openLayoutEditor?() }
        needs(layout, .layoutEditor, availability)
        menu.addItem(layout)
        menu.addItem(entry(PermissionText.setUpMenuTitle) { c.openSetup?(nil) })
        menu.addItem(entry("Settings…", keyEquivalent: ",") { openSettings() })
        let login = entry("Launch at Login") { c.setLaunchAtLogin(!c.loginItemEnabled) }
        login.state = c.loginItemEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(entry("About SnugBar") { openAbout() })
        if updater.isAvailable {
            menu.addItem(CheckForUpdatesMenuItem(updater: updater))
        }
        menu.addItem(.separator())
        menu.addItem(entry("Quit SnugBar", keyEquivalent: "q") { NSApp.terminate(nil) })
        return menu
    }

    /// A feature the current permissions don't allow is disabled, with the reason as the item's second line.
    private static func needs(_ item: NSMenuItem, _ feature: AppFeature, _ availability: FeatureAvailability, enabled: Bool = true) {
        if let reason = availability.reason(feature) {
            item.isEnabled = false
            item.subtitle = reason
        } else {
            item.isEnabled = enabled
        }
    }

    private static func hotkeyHint(_ c: AppController, _ action: HotkeyAction) -> Hotkey? {
        c.settings.hotkeys[action]
    }

    /// A menu entry. A global shortcut is shown on the right like a key equivalent when it is a single character.
    private static func entry(_ title: String, key hotkey: Hotkey? = nil, keyEquivalent: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: keyEquivalent, action: action)
        if let hotkey {
            let name = KeyNames.name(for: hotkey.keyCode)
            if name.count == 1 {
                item.keyEquivalent = name.lowercased()
                var flags: NSEvent.ModifierFlags = []
                if hotkey.modifiers.contains(.command) { flags.insert(.command) }
                if hotkey.modifiers.contains(.option) { flags.insert(.option) }
                if hotkey.modifiers.contains(.control) { flags.insert(.control) }
                if hotkey.modifiers.contains(.shift) { flags.insert(.shift) }
                item.keyEquivalentModifierMask = flags
            }
        }
        return item
    }

    private static func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController()
    private let updater = Updater()
    private lazy var control = ControlSurface(controller: controller)
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private lazy var layoutEditor = LayoutEditorController(controller: controller) { [weak self] pane in self?.showSettings(pane: pane) }
    private lazy var setup = SetupWindowController(controller: controller) { [weak self] pane in self?.showSettings(pane: pane) }
    private let settingsNavigation = SettingsNavigation(defaults: .standard)
    private var settingsCancellables: Set<AnyCancellable> = []
    private var signalSources: [DispatchSourceSignal] = []
    private var didFinishLaunching = false

    /// `snugbar://` links arrive as Apple events. Registered before launch finishes so a link that launches SnugBar
    /// is handled too.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsFileExisted = FileManager.default.fileExists(atPath: SettingsStore.defaultURL.path)
        statusItem = StatusItemController(
            controller: controller, updater: updater,
            openSettings: { [weak self] in self?.showSettings() }, openAbout: { [weak self] in self?.showAbout() }
        )
        updater.activate = { [weak self] in self?.activateForOwnWindow() }
        AppMenu.install(updater: updater, about: { [weak self] in self?.showAbout() },
                        settings: { [weak self] in self?.showSettings() })
        controller.openLayoutEditor = { [weak self] in self?.showLayoutEditor() }
        controller.openSetup = { [weak self] step in self?.setup.show(step: step) }
        controller.start()
        control.start()
        // After everything else is up; never in a --debug run (those don't reach this delegate).
        updater.start()
        handleTerminationSignals()
        // Activations during launch are not the user asking for the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.didFinishLaunching = true }
        // Setup never finished (feature 85): it explains the permissions. Otherwise, with the icon turned off, open
        // Settings so SnugBar can be found.
        if controller.setupShouldShowAtLaunch(settingsFileExisted: settingsFileExisted) {
            setup.show()
        } else if !controller.settings.showIcon {
            showSettings()
        }
    }

    /// The layout editor reads the menu bar; without Accessibility the setup window explains what is missing.
    private func showLayoutEditor() {
        if controller.checkAvailable(.layoutEditor) {
            layoutEditor.show()
        } else {
            setup.show(step: .accessibility)
        }
    }

    /// Every quit ends here: the menu's Quit, ⌘Q, SIGTERM/SIGINT, Restart, and Sparkle's "Install and Relaunch" (its
    /// installer asks the app to quit and waits for the process to exit before replacing the bundle). The control
    /// server stops listening and the hide is lifted (the system would also end it when the process exits).
    func applicationWillTerminate(_ notification: Notification) {
        control.stop()
        controller.stop()
    }

    private func showAbout() {
        AboutPanel.show { activateForOwnWindow() }
    }

    /// Activates SnugBar for a window that isn't Settings (About, Sparkle's), so the activation doesn't also open
    /// Settings (see `applicationDidBecomeActive`).
    private func activateForOwnWindow() {
        ownActivationAt = Date()
        NSApp.activate()
    }

    /// When SnugBar last activated itself for About or an update window.
    private var ownActivationAt = Date.distantPast

    /// Identifies the sending app (its pid from the event, then its bundle ID) so consent can be remembered per app.
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        lastLinkAt = Date()
        var pid: pid_t?
        if let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)), sender.int32Value > 0 {
            pid = sender.int32Value
        } else if let address = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)),
                  address.descriptorType == DescType(typeKernelProcessID), address.int32Value > 0 {
            pid = address.int32Value
        }
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        control.open(url, caller: .init(bundleID: app?.bundleIdentifier, name: app?.localizedName))
    }

    /// Opening SnugBar again (Finder, Spotlight, `open`) shows Settings: the way back when the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Launch Services only activates an already running menu bar app when it is opened again (no reopen event), so
    /// an activation with no window open is treated the same way.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching, settingsWindow?.isVisible != true, !layoutEditor.isVisible, !setup.isVisible else { return }
        // Opening a snugbar:// link can activate SnugBar too (before or after the link arrives); that isn't a request
        // for the window, so wait a moment to see whether a link came with this activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastLinkAt) > 1.5, self.settingsWindow?.isVisible != true,
                  !self.layoutEditor.isVisible, !self.setup.isVisible,
                  Date().timeIntervalSince(self.ownActivationAt) > 1.5,
                  // Another titled window of SnugBar's is up (the About panel, Sparkle's update window).
                  !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
            self.showSettings()
        }
    }

    /// When the last `snugbar://` link arrived.
    private var lastLinkAt = Date.distantPast

    /// Opens Settings, on `pane` when given (otherwise on the pane selected last).
    func showSettings(pane: SettingsPane? = nil) {
        if let pane { settingsNavigation.pane = pane }
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: SettingsWindow.defaultContentSize),
                styleMask: SettingsWindow.styleMask, backing: .buffered, defer: false
            )
            SettingsWindow.configure(window, controller: controller, control: control, updater: updater,
                                     navigation: settingsNavigation)
            window.setFrameAutosaveName(SettingsWindow.autosaveName)
            if window.setFrameUsingName(SettingsWindow.autosaveName) {
                // A frame saved by the older, narrower tabbed window is grown to the new minimum.
                let content = window.contentRect(forFrameRect: window.frame).size
                if content.width < SettingsView.minSize.width || content.height < SettingsView.minSize.height {
                    let top = window.frame.maxY
                    window.setContentSize(NSSize(width: max(content.width, SettingsWindow.defaultContentSize.width),
                                                 height: max(content.height, SettingsWindow.defaultContentSize.height)))
                    window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
                }
            } else {
                window.center()
            }
            settingsNavigation.$pane
                .sink { [weak window] pane in window?.title = pane.title }
                .store(in: &settingsCancellables)
            settingsWindow = window
        }
        controller.refreshPermissions()
        controller.noteVisibleApps()
        // SnugBar stays an accessory app (no Dock icon) while Settings is open: switching to `.regular` at runtime
        // stops SwiftUI pop-up menus from appearing on macOS 27 (the menu tracks but its window never shows).
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// SIGTERM / SIGINT quit through the normal path so the hide is lifted cleanly.
    private func handleTerminationSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                RunLoop.main.perform { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
