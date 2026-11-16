import AppKit
import ApplicationServices
import ScreenCaptureKit
import SnugBarCore

/// Permission status and requests.
@MainActor
public enum Permissions {
    public struct Status: Codable, Sendable {
        public var accessibility: Bool
        /// This process's own preflight answer (see `screenRecordingInProcess`).
        public var screenRecording: Bool
        public var orderFileAccess: OrderFileAccess.Status
    }

    public static func status(orderFile: OrderFileAccess) -> Status {
        Status(accessibility: accessibility, screenRecording: screenRecordingInProcess, orderFileAccess: orderFile.status)
    }

    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// `CGPreflightScreenCaptureAccess()` in this process. Right at launch, but it keeps its first answer for the
    /// life of the process, so a running app must not rely on it later: `ScreenRecordingAccess` with
    /// `freshScreenRecording()` and `probeScreenCapture()` tracks the real state.
    public static var screenRecordingInProcess: Bool { CGPreflightScreenCaptureAccess() }

    /// The bundled command-line helper (`Contents/Helpers/snugbar`), when this copy is an app bundle.
    public nonisolated static var helperURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/snugbar")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Whether Screen Recording is allowed now, asked from a fresh process: the bundled helper with
    /// `--preflight-screen-recording` prints its own `CGPreflightScreenCaptureAccess()`. A process SnugBar starts is
    /// attributed to SnugBar by TCC, and a new process has no stale answer. Never prompts; takes a few milliseconds
    /// (the helper is waited for at most 2 s). Nil without the helper (an unbundled build) or when it fails.
    public nonisolated static func freshScreenRecording(helper: URL? = helperURL) async -> Bool? {
        guard let helper else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = helper
                process.arguments = [ScreenRecordingAccess.preflightFlag]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: deadline)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                deadline.cancel()
                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: ScreenRecordingAccess.parsePreflight(String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Whether this process can capture: asks ScreenCaptureKit for the shareable content, which it refuses with a
    /// permission error when this process isn't allowed (no picture is taken). Only call it when the system allows
    /// Screen Recording (`freshScreenRecording`): without the permission it could prompt.
    public static func probeScreenCapture() async -> ScreenRecordingAccess.Outcome {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .succeeded
        } catch {
            return ItemImager.isPermissionError(error) ? .refused : .failed
        }
    }

    /// Shows the system prompt (once per app) and opens the Device Control and Data Access pane.
    public static func requestAccessibility() {
        // The documented key behind `kAXTrustedCheckOptionPrompt`.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openSettings(for: .accessibility)
        }
    }

    public static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            openSettings(for: .screenRecording)
        }
    }

    /// Opens the permission's pane in System Settings > Privacy & Security (the anchors are in `SystemSettingsNames`).
    static func openSettings(for permission: PermissionKind) {
        guard let anchor = permission.settingsAnchor,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
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
