import AppKit
import Combine
import Sparkle

/// In-app updates via Sparkle (feature 89). Owns the single updater controller and publishes what the menu and
/// Settings show. The only network request SnugBar makes is this update check, to GitHub.
///
/// SnugBar is an accessory app: an update found by a scheduled check while the user is busy elsewhere becomes a quiet
/// "Update Available" entry at the top of SnugBar's menu ("gentle reminder") instead of an alert behind other windows.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// User default that overrides the appcast URL, for maintainers testing an update against a local feed. Updates
    /// are still verified against `SUPublicEDKey`, so this can't install a build that isn't signed with SnugBar's key.
    nonisolated static let feedOverrideDefaultsKey = "SnugBarUpdateFeedURL"

    /// False outside an .app bundle with a feed (`swift run`, tests): Sparkle needs the Info.plist keys and a bundle
    /// to replace, and development runs shouldn't reach the network.
    let isAvailable: Bool
    @Published private(set) var canCheckForUpdates = false
    /// The version of an update a scheduled check found and left for SnugBar to present.
    @Published private(set) var pendingUpdateVersion: String?
    /// Brings SnugBar forward before a window of its own opens (set by the app delegate).
    var activate: () -> Void = { NSApp.activate() }

    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    /// Offscreen snapshots: shows the controls with these values, never creates Sparkle's updater.
    private let preview: (automaticChecks: Bool, pending: String?)?

    override init() {
        let bundle = Bundle.main
        isAvailable = bundle.bundleURL.pathExtension == "app" && bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil
        preview = nil
        super.init()
    }

    /// An updater for `--debug` renders: available, never started, nothing checked.
    init(previewAutomaticChecks: Bool, pendingUpdateVersion: String? = nil) {
        isAvailable = true
        preview = (previewAutomaticChecks, pendingUpdateVersion)
        super.init()
        self.pendingUpdateVersion = pendingUpdateVersion
    }

    /// Call once from `applicationDidFinishLaunching`. Never in a `--debug` run. Sparkle's delegates are weak; the app
    /// delegate keeps `self` alive.
    func start() {
        guard isAvailable, preview == nil, controller == nil,
              DebugInvocation(arguments: CommandLine.arguments) == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        observations.append(controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // The KVO closure isn't actor-isolated, but SPUUpdater only changes this on the main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        })
        controller.startUpdater()
    }

    /// Bound to "Check for updates automatically". Sparkle stores it in SnugBar's user defaults (not settings.json).
    var automaticallyChecksForUpdates: Bool {
        get { preview?.automaticChecks ?? controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// When the last check ran, if Sparkle has checked before.
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    /// A check the user asked for. With an update already found, this brings its window forward.
    func checkForUpdates() {
        guard let controller else { return }
        // SnugBar isn't active when its menu is used; without this Sparkle's window can open behind other apps.
        activate()
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        guard let s = UserDefaults.standard.string(forKey: Updater.feedOverrideDefaultsKey), !s.isEmpty else { return nil }
        return s
    }
}

// Sparkle calls the user driver delegate on the main thread, but the protocol isn't annotated that way.
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows its own alert only when it would be in front (for example right after launch); otherwise the menu
    /// gets an entry and SnugBar waits for the user to choose it.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { pendingUpdateVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { pendingUpdateVersion = nil }
    }
}
