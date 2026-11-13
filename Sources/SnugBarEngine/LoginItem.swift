import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (feature 88). The system's status is the source of truth; it only
/// works when SnugBar runs from an app bundle.
@MainActor
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The user must approve SnugBar in System Settings → General → Login Items.
    public static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
