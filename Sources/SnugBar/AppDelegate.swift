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
    private let openSettings: () -> Void
    private var item: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    init(controller: AppController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
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
    }

    private func updateIcon(state: BarState, hasError: Bool) {
        let symbol: String
        if !controller.accessibilityGranted || hasError {
            symbol = "exclamationmark.triangle"
        } else if state.zen {
            symbol = "eye.slash"
        } else if state.swapped && state.reveal == .collapsed {
            symbol = "arrow.left.arrow.right"
        } else {
            switch state.reveal {
            case .collapsed: symbol = "chevron.left"
            case .expanded: symbol = "chevron.right"
            case .all: symbol = "chevron.right.2"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "SnugBar")
        image?.isTemplate = true
        item?.button?.image = image
        if state.zen {
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
        let menu = NSMenu()
        let c = controller
        let state = c.state

        let show = entry(state.reveal == .collapsed ? "Show Hidden Items" : "Hide Items", key: hotkeyHint(.toggleHidden)) { c.toggle() }
        show.isEnabled = !state.zen
        menu.addItem(show)
        let always = entry(state.reveal == .all ? "Hide Always Hidden Items" : "Show Always Hidden Items", key: hotkeyHint(.toggleAlwaysHidden)) {
            c.toggleAlwaysHidden()
        }
        always.isEnabled = !state.zen
        menu.addItem(always)
        let swap = entry("Swap Shown and Hidden", key: hotkeyHint(.swap)) { c.swap() }
        swap.state = state.swapped ? .on : .off
        swap.isEnabled = c.supportsSwap && !state.zen
        menu.addItem(swap)
        // After the menu has closed, so the palette can take keyboard focus.
        let search = entry("Search…", key: hotkeyHint(.search)) { DispatchQueue.main.async { c.showSearch() } }
        search.isEnabled = !state.zen
        menu.addItem(search)
        let zen = entry("Zen Mode", key: hotkeyHint(.zen)) { c.toggleZen() }
        zen.state = state.zen ? .on : .off
        menu.addItem(zen)

        menu.addItem(.separator())
        menu.addItem(info(c.backendDescription))
        if !c.accessibilityGranted {
            menu.addItem(entry("Grant Accessibility…") { c.grantAccessibility() })
        }
        if !c.isRunningFromApplications {
            menu.addItem(info("Move SnugBar to Applications: its icon is hidden with other apps when it runs from elsewhere."))
        }
        if let error = c.lastError {
            menu.addItem(info(error))
        }

        menu.addItem(.separator())
        menu.addItem(entry("Settings…", keyEquivalent: ",") { [openSettings] in openSettings() })
        let login = entry("Launch at Login") { c.setLaunchAtLogin(!c.loginItemEnabled) }
        login.state = c.loginItemEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(entry("Quit SnugBar", keyEquivalent: "q") { NSApp.terminate(nil) })
        return menu
    }

    private func hotkeyHint(_ action: HotkeyAction) -> Hotkey? {
        controller.settings.hotkeys[action]
    }

    /// A menu entry. A global shortcut is shown on the right like a key equivalent when it is a single character.
    private func entry(_ title: String, key hotkey: Hotkey? = nil, keyEquivalent: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
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

    private func info(_ text: String) -> NSMenuItem {
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
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(controller: controller) { [weak self] in self?.showSettings() }
        controller.start()
        handleTerminationSignals()
        // Activations during launch are not the user asking for the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.didFinishLaunching = true }
        // First launch, or the icon is turned off: open Settings so SnugBar can be found.
        if !controller.settings.showIcon || !FileManager.default.fileExists(atPath: SettingsStore.defaultURL.path) {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// Opening SnugBar again (Finder, Spotlight, `open`) shows Settings: the way back when the icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Launch Services only activates an already running menu bar app when it is opened again (no reopen event), so
    /// an activation with no window open is treated the same way.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard didFinishLaunching, settingsWindow?.isVisible != true else { return }
        showSettings()
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
            )
            window.title = "SnugBar Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView(controller: controller))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("SnugBarSettings")
            if !window.setFrameUsingName("SnugBarSettings") { window.center() }
            settingsWindow = window
        }
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
