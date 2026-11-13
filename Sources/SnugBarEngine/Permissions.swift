import AppKit
import ApplicationServices

/// Permission status and requests.
@MainActor
public enum Permissions {
    public struct Status: Codable, Sendable {
        public var accessibility: Bool
        public var screenRecording: Bool
        public var orderFileAccess: OrderFileAccess.Status
    }

    public static func status(orderFile: OrderFileAccess) -> Status {
        Status(accessibility: accessibility, screenRecording: screenRecording, orderFileAccess: orderFile.status)
    }

    public static var accessibility: Bool { AXIsProcessTrusted() }

    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (once per app) and opens the Accessibility pane.
    public static func requestAccessibility() {
        // The documented key behind `kAXTrustedCheckOptionPrompt`.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings(anchor: "Privacy_Accessibility")
        }
    }

    public static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings(anchor: "Privacy_ScreenCapture")
        }
    }

    static func openSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// System facts for reports.
public enum SystemInfo {
    public static var version: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Build number, e.g. `26B123`.
    public static var build: String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
