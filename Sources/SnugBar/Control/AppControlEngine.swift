import AppKit
import SnugBarCore
import SnugBarEngine

/// The control commands' engine in the running app: everything goes through `AppController`, so a command does
/// exactly what the same action in SnugBar's own UI does.
@MainActor
final class AppControlEngine: ControlEngine {
    private unowned let controller: AppController
    /// The port and token setting reported by `status`.
    private let server: () -> (port: Int, tokenRequired: Bool)

    init(controller: AppController, server: @escaping () -> (port: Int, tokenRequired: Bool)) {
        self.controller = controller
        self.server = server
    }

    func controlItems() -> [ControlEngineItem] { controller.controlItems() }
    var sections: AppSectionMap { controller.settings.sections }
    var barState: BarState { controller.state }
    var recentItems: [ItemID] { controller.settings.recentItems }
    var canRevealSingleApp: Bool { controller.canRevealSingleApp }
    var supportsSwap: Bool { controller.supportsSwap }
    var arranger: ControlArranger? { controller.controlArranger }

    func reveal(bundleID: String) throws { controller.revealApp(bundleID) }

    func hide(bundleID: String) throws { controller.hideApp(bundleID) }

    func click(_ item: MenuBarItem) async throws -> String {
        guard Permissions.accessibility else {
            throw ControlError(.unavailable, PermissionText.needsAccessibility("Opening an item"))
        }
        do {
            return try await controller.open(item).method.rawValue
        } catch let error as ItemActivator.ActivationError {
            throw ControlError(.failed, error.description)
        }
    }

    func setSection(_ section: Section, forBundleIDs bundleIDs: [String]) {
        controller.setSection(section, for: bundleIDs)
    }

    func order(_ item: MenuBarItem, _ placement: ControlPlacement) async throws -> ControlArranger {
        do {
            return try await controller.order(item, placement)
        } catch let error as Arranger.ArrangeError {
            throw ControlError(.failed, error.description)
        } catch let error as OrderFileAccess.AccessError {
            throw ControlError(.failed, error.description)
        } catch let error as OrderPlanner.PlanError {
            throw ControlError(.failed, error.description)
        }
    }

    func setReveal(_ level: RevealLevel) {
        // From the command line: don't take keyboard focus from the terminal or agent.
        if level == .collapsed { controller.collapse() } else { controller.setReveal(level, focusBar: false) }
    }

    func swap() { controller.swap() }

    func setZen(_ on: Bool) { controller.setZen(on) }

    func statusInfo() -> ControlStatusInfo {
        let s = server()
        return ControlStatusInfo(
            hider: controller.hiderBackendName,
            permissions: ControlPermissions(
                accessibility: Permissions.accessibility,
                screenRecording: Permissions.screenRecording,
                menuBarFolder: controller.hasOrderFileAccess
            ),
            version: AppInfo.version,
            port: s.port,
            tokenRequired: s.tokenRequired
        )
    }
}

enum AppInfo {
    /// `CFBundleShortVersionString`, or `dev` for an unbundled build.
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
