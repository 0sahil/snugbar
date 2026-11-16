import AppKit
import Combine
import SnugBarCore
import SnugBarEngine
import SwiftUI

/// The setup window's page and its buttons' actions. The app wires the actions to `AppController`; offscreen
/// snapshots leave them empty.
@MainActor
final class SetupModel: ObservableObject {
    struct Actions {
        var requestAccessibility: () -> Void = {}
        var requestScreenRecording: () -> Void = {}
        var chooseFolder: () -> Void = {}
        var restart: () -> Void = {}
        var setLaunchAtLogin: (Bool) -> Void = { _ in }
        var openLoginItems: () -> Void = {}
        var openSettings: () -> Void = {}
        var finish: () -> Void = {}
    }

    @Published var flow: SetupFlow
    var actions = Actions()

    init(step: SetupStep = .welcome) {
        flow = SetupFlow(step: step)
    }
}

/// One page per step (feature 85): what the permission is for, what works without it, its status and a button.
/// Plain native controls; the window is about 560 points wide.
struct SetupView: View {
    static let size = CGSize(width: 560, height: 450)

    @ObservedObject var model: SetupModel
    @ObservedObject var controller: AppController

    private var grants: PermissionGrants { controller.shownGrants }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.flow.step.title)
                    .font(.title2.weight(.semibold))
                page
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 12)
            Divider()
            buttons
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    @ViewBuilder private var page: some View {
        switch model.flow.step {
        case .welcome:
            paragraph(PermissionText.welcome)
            paragraph(PermissionText.welcomeDetail)
        case .accessibility, .screenRecording, .menuBarFolder:
            if let permission = model.flow.step.permission { permissionPage(permission) }
        case .done:
            donePage
        }
    }

    private func permissionPage(_ permission: PermissionKind) -> some View {
        let granted = grants.has(permission)
        return VStack(alignment: .leading, spacing: 14) {
            paragraph(permission.purpose)
            paragraph(permission.withoutIt).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                PermissionStatusLabel(permission: permission, granted: granted)
                Spacer()
                if !granted {
                    Button(permission.buttonTitle) { action(for: permission)() }
                }
            }
            .padding(.top, 4)
            if permission == .screenRecording, controller.screenRecording.needsRestart {
                HStack(spacing: 8) {
                    paragraph(PermissionText.restartForScreenRecording)
                    Spacer()
                    Button(PermissionText.restartButton) { model.actions.restart() }
                }
            }
            if model.flow.showsReducedModeNote(grants: grants) {
                paragraph(PermissionText.reducedMode).foregroundStyle(.secondary)
            }
        }
    }

    private var donePage: some View {
        let availability = controller.availability
        return VStack(alignment: .leading, spacing: 10) {
            paragraph(PermissionText.doneIntro)
            VStack(alignment: .leading, spacing: 5) {
                ForEach(AppFeature.summary, id: \.self) { feature in
                    let entry = availability.entry(feature)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: entry.available ? "checkmark" : "minus")
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(entry.title)
                            .foregroundStyle(entry.available ? .primary : .secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let reason = entry.reason {
                            Text(reason).font(.callout).foregroundStyle(.secondary)
                                .lineLimit(1).fixedSize()
                        }
                    }
                }
            }
            .padding(.leading, 2)
            if availability.isReduced {
                paragraph(PermissionText.reducedMode).foregroundStyle(.secondary)
            }
            Toggle("Launch at login", isOn: Binding(
                get: { controller.loginItemEnabled }, set: { model.actions.setLaunchAtLogin($0) }
            ))
            .padding(.top, 4)
            if controller.loginItemNeedsApproval {
                HStack {
                    Text("Allow SnugBar in Login Items to finish.").foregroundStyle(.secondary)
                    Button("Open Login Items") { model.actions.openLoginItems() }
                }
            }
            paragraph(PermissionText.doneChangeLater).foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if let progress = model.flow.progressText {
                Text(progress).foregroundStyle(.secondary)
            }
            Spacer()
            if model.flow.canGoBack {
                Button("Back") { model.flow.back() }
            }
            if model.flow.isLast {
                Button("Open Settings") { model.actions.openSettings() }
                Button("Done") { model.actions.finish() }
                    .keyboardShortcut(.defaultAction)
            } else if let title = model.flow.forwardTitle(grants: grants) {
                Button(title) { model.flow.forward() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func action(for permission: PermissionKind) -> () -> Void {
        switch permission {
        case .accessibility: return model.actions.requestAccessibility
        case .screenRecording: return model.actions.requestScreenRecording
        case .menuBarFolder: return model.actions.chooseFolder
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }
}

/// "Allowed" with a checkmark, or "Not allowed" with an empty circle (the folder: "Chosen" / "Not chosen").
struct PermissionStatusLabel: View {
    let permission: PermissionKind
    let granted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
            Text(permission.statusText(granted: granted))
        }
    }
}

// MARK: - Window

@MainActor
enum SetupWindow {
    static let styleMask: NSWindow.StyleMask = [.titled, .closable]
    static let autosaveName = "SnugBarSetup"

    static func configure(_ window: NSWindow, model: SetupModel, controller: AppController) {
        let hosting = NSHostingController(rootView: SetupView(model: model, controller: controller))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.title = PermissionText.setupWindowTitle
        window.setContentSize(SetupView.size)
        window.isReleasedWhenClosed = false
    }
}

/// Opens the setup window and keeps its status live: permissions are checked every second while it is open (macOS
/// sends no notification when they change) and when SnugBar becomes active. Closing it, or Done, marks setup as
/// completed. It changes nothing in the menu bar itself: a grant only lets the app do what it does at launch.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let controller: AppController
    private let model = SetupModel()
    private var window: NSWindow?
    private var timer: Timer?

    init(controller: AppController, openSettings: @escaping (SettingsPane?) -> Void) {
        self.controller = controller
        super.init()
        let c = controller
        model.actions = .init(
            requestAccessibility: { c.grantAccessibility() },
            requestScreenRecording: { c.grantScreenRecording() },
            chooseFolder: { c.grantOrderFileAccess() },
            restart: { AppRelauncher.relaunch() },
            setLaunchAtLogin: { c.setLaunchAtLogin($0) },
            openLoginItems: { LoginItem.openSystemSettings() },
            openSettings: { [weak self] in
                self?.window?.close()
                openSettings(nil)
            },
            finish: { [weak self] in self?.window?.close() }
        )
    }

    var isVisible: Bool { window?.isVisible == true }

    /// - Parameter step: the page to open on; nil starts at the beginning unless the window is already open.
    func show(step: SetupStep? = nil) {
        let wasVisible = isVisible
        if window == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SetupView.size),
                                  styleMask: SetupWindow.styleMask, backing: .buffered, defer: false)
            SetupWindow.configure(window, model: model, controller: controller)
            window.center()
            window.delegate = self
            self.window = window
        }
        if let step {
            model.flow.go(to: step)
        } else if !wasVisible {
            model.flow = SetupFlow()
        }
        controller.refreshPermissions()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        startPolling()
    }

    private func startPolling() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.controller.refreshPermissions()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        controller.markSetupCompleted()
    }
}

/// Restarts SnugBar: a detached shell waits for this process to exit, then opens the app again; SnugBar quits through
/// the normal path (which lifts the hide cleanly).
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The pid and the bundle path are passed as arguments, not spliced into the script.
        process.arguments = [
            "-c", "sleep 0.5; while /bin/kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$2\"",
            "snugbar-relaunch", "\(pid)", Bundle.main.bundlePath,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            NSLog("SnugBar: could not restart: %@", String(describing: error))
            NSSound.beep()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
