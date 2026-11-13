import SnugBarCore
import SnugBarEngine
import SwiftUI

struct SnugBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Button(model.isCollapsed ? "Expand" : "Collapse") { model.toggle() }
                .keyboardShortcut("h")
            Text(model.backendDescription)
            if let error = model.lastError {
                Text(error)
            }
            Divider()
            Button(model.accessibilityGranted ? "Accessibility: Granted" : "Grant Accessibility…") {
                model.grantAccessibility()
            }
            .disabled(model.accessibilityGranted)
            Button(model.screenRecordingGranted ? "Screen Recording: Granted" : "Grant Screen Recording…") {
                model.grantScreenRecording()
            }
            .disabled(model.screenRecordingGranted)
            Button(model.orderFileGranted ? "Menu Bar Layout Access: Granted" : "Grant Menu Bar Layout Access…") {
                model.grantOrderFileAccess()
            }
            .disabled(model.orderFileGranted)
            Divider()
            Button("Quit SnugBar") { model.quit() }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: model.isCollapsed ? "menubar.arrow.up.rectangle" : "menubar.rectangle")
                .accessibilityLabel("SnugBar")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// M1 app state: one collapse/expand toggle driven by the settings file.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isCollapsed = false
    @Published private(set) var lastError: String?
    @Published private(set) var accessibilityGranted = Permissions.accessibility
    @Published private(set) var screenRecordingGranted = Permissions.screenRecording
    @Published private(set) var orderFileGranted = false

    private let reader = MenuBarReader()
    private let assessment = AssessmentHider()
    private let divider = OverflowDividerHider()
    private let orderFile = OrderFileAccess()
    private lazy var notificationGuard = NotificationCenterGuard(hider: assessment, reader: reader)
    private let store = SettingsStore(url: SettingsStore.defaultURL)
    private var settings = Settings.default
    private var activeHider: Hider?
    private var activationObserver: NSObjectProtocol?

    init() {
        do {
            settings = try store.load()
        } catch {
            lastError = "Settings not loaded: \(error)"
        }
        orderFileGranted = orderFile.status == .granted
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
    }

    var backendDescription: String {
        switch preferredHider().backend {
        case .assessment: return "Hiding: per app (system)"
        case .overflowDivider:
            return assessment.isAvailable ? "Hiding: divider" : "Hiding: divider (per-app hiding unavailable)"
        }
    }

    func toggle() {
        isCollapsed ? expand() : collapse()
    }

    func collapse() {
        let hider = preferredHider()
        // Every third-party app is hidden except the ones listed as shown, and SnugBar itself.
        var allowed = settings.sections.bundleIDs(in: .shown)
        if let own = Bundle.main.bundleIdentifier { allowed.insert(own) }
        do {
            try hider.hide(allowing: allowed)
            activeHider = hider
            if hider === assessment { notificationGuard.start() }
            isCollapsed = true
            lastError = nil
        } catch {
            lastError = "\(error)"
        }
    }

    func expand() {
        notificationGuard.stop()
        activeHider?.show()
        activeHider = nil
        isCollapsed = false
    }

    func grantAccessibility() {
        Permissions.requestAccessibility()
        refreshPermissions()
    }

    func grantScreenRecording() {
        Permissions.requestScreenRecording()
        refreshPermissions()
    }

    func grantOrderFileAccess() {
        orderFile.requestAccess()
        refreshPermissions()
    }

    func quit() {
        expand()
        NSApp.terminate(nil)
    }

    private func refreshPermissions() {
        accessibilityGranted = Permissions.accessibility
        screenRecordingGranted = Permissions.screenRecording
        orderFileGranted = orderFile.status == .granted
    }

    private func preferredHider() -> Hider {
        switch settings.hider {
        case .assessment: return assessment
        case .overflowDivider: return divider
        case .automatic: return assessment.isAvailable ? assessment : divider
        }
    }
}
