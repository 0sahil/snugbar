import AppKit
import SnugBarCore
import SnugBarEngine
import SwiftUI

/// Which Settings pane is selected. The last one is remembered in UserDefaults (not in settings.json).
@MainActor
final class SettingsNavigation: ObservableObject {
    static let defaultsKey = "SettingsSelectedPane"

    @Published var pane: SettingsPane {
        didSet { defaults?.set(pane.rawValue, forKey: Self.defaultsKey) }
    }

    private let defaults: UserDefaults?

    /// - Parameter defaults: where the selection is remembered; nil remembers nothing (offscreen snapshots).
    init(defaults: UserDefaults?, pane: SettingsPane? = nil) {
        self.defaults = defaults
        self.pane = pane ?? defaults?.string(forKey: Self.defaultsKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
    }
}

/// Settings: the panes in a sidebar on the left, the selected pane on the right.
struct SettingsView: View {
    static let minSize = CGSize(width: 680, height: 460)

    @ObservedObject var controller: AppController
    @ObservedObject var control: ControlSurface
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        // The sidebar always stays: the visibility is fixed and its toolbar toggle removed.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(navigation: navigation)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            pane(navigation.pane)
                .navigationTitle(navigation.pane.title)
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
    }

    @ViewBuilder
    private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralSettings(controller: controller)
        case .sections: SectionsSettings(controller: controller)
        case .shortcuts: ShortcutSettings(controller: controller)
        case .control: ControlSettings(controller: controller, control: control)
        case .permissions: PermissionSettings(controller: controller)
        }
    }
}

private struct SettingsSidebar: View {
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        // Selecting nothing (e.g. ⌘-clicking the selected row) keeps the current pane.
        List(selection: Binding<SettingsPane?>(
            get: { navigation.pane },
            set: { if let pane = $0 { navigation.pane = pane } }
        )) {
            ForEach(SettingsPane.allCases) { pane in
                Label(pane.title, systemImage: pane.systemImage).tag(pane)
            }
        }
        .listStyle(.sidebar)
    }
}

/// The Settings window: a titled, resizable AppKit window hosting `SettingsView`, whose title is the selected pane.
/// SnugBar stays an accessory app while it is open (see `AppDelegate.showSettings`).
@MainActor
enum SettingsWindow {
    static let defaultContentSize = NSSize(width: 760, height: 520)
    static let autosaveName = "SnugBarSettings"

    static func configure(_ window: NSWindow, controller: AppController, control: ControlSurface, navigation: SettingsNavigation) {
        let hosting = NSHostingController(rootView: SettingsView(controller: controller, control: control, navigation: navigation))
        // The toolbar (sidebar look, no sidebar toggle) and the title come from the SwiftUI view.
        hosting.sceneBridgingOptions = [.title, .toolbars]
        window.contentViewController = hosting
        window.toolbarStyle = .unified
        window.title = navigation.pane.title
        window.contentMinSize = SettingsView.minSize
        window.setContentSize(defaultContentSize)
        window.isReleasedWhenClosed = false
    }

    static let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
}

/// A binding into one settings field that saves through the controller.
@MainActor
private func setting<T>(_ controller: AppController, _ path: WritableKeyPath<SnugBarCore.Settings, T>) -> Binding<T> {
    Binding(get: { controller.settings[keyPath: path] }, set: { value in controller.update { $0[keyPath: path] = value } })
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section {
                Toggle("Show SnugBar in the menu bar", isOn: setting(controller, \.showIcon))
                if !controller.settings.showIcon {
                    Text(noIconHint).font(.callout).foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.loginItemEnabled }, set: { controller.setLaunchAtLogin($0) }
                ))
                if controller.loginItemNeedsApproval {
                    HStack {
                        Text("Allow SnugBar in Login Items to finish.").font(.callout).foregroundStyle(.secondary)
                        Button("Open Login Items") { LoginItem.openSystemSettings() }
                    }
                }
            }

            Section {
                Picker("Show hidden items in", selection: setting(controller, \.revealIn)) {
                    Text("SnugBar Bar").tag(RevealDestination.snugBarBar)
                    Text("Menu bar").tag(RevealDestination.menuBar)
                }
                Toggle("Move items that don’t fit into Hidden", isOn: setting(controller, \.moveItemsThatDontFit))
            } header: {
                Text("Hidden items")
            } footer: {
                Text("The SnugBar Bar opens below the menu bar. Items that don’t fit beside the notch are listed there under “Didn’t Fit” instead of going behind the system’s overflow button.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Hide again automatically") {
                Toggle("After a delay", isOn: setting(controller, \.autoCollapse.enabled))
                if controller.settings.autoCollapse.enabled {
                    LabeledContent("Delay") {
                        HStack {
                            Slider(value: setting(controller, \.autoCollapse.delay), in: AutoCollapseSettings.delayRange, step: 1)
                            Text("\(Int(controller.settings.autoCollapse.delay)) s").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    Toggle("When I click outside the menu bar", isOn: setting(controller, \.autoCollapse.onClickOutside))
                    Toggle("When I switch apps", isOn: setting(controller, \.autoCollapse.onAppSwitch))
                    Text("Items stay while one of their menus is open.").font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Show hidden items by") {
                Toggle("Clicking an empty part of the menu bar", isOn: setting(controller, \.reveal.clickEmptyBar))
                Toggle("Resting the pointer on the menu bar", isOn: setting(controller, \.reveal.hover))
                if controller.settings.reveal.hover {
                    LabeledContent("Wait") {
                        HStack {
                            Slider(value: setting(controller, \.reveal.hoverDelay), in: RevealSettings.hoverDelayRange, step: 0.1)
                            Text(String(format: "%.1f s", controller.settings.reveal.hoverDelay)).monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Toggle("Scrolling on the menu bar (down shows, up hides)", isOn: setting(controller, \.reveal.scroll))
            }

            Section("Hiding") {
                Picker("Method", selection: setting(controller, \.hider)) {
                    Text("Automatic").tag(HiderPreference.automatic)
                    Text("Whole apps (system)").tag(HiderPreference.assessment)
                    Text("Divider").tag(HiderPreference.overflowDivider)
                }
                Text(controller.backendDescription).font(.callout).foregroundStyle(.secondary)
                if let error = controller.lastError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
                if !controller.isRunningFromApplications {
                    Text("SnugBar is not in the Applications folder, so its own icon is hidden along with other apps.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            Section("Settings file") {
                HStack {
                    Text(SettingsStore.defaultURL.path(percentEncoded: false)).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") { controller.revealSettingsFile() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var noIconHint: String {
        var ways: [String] = []
        if let key = controller.settings.hotkeys.toggleHidden { ways.append("press \(key)") }
        if controller.settings.reveal.clickEmptyBar { ways.append("click an empty part of the menu bar") }
        let how = ways.isEmpty ? "Set a shortcut first, or you can only reveal items from this window." : "To show hidden items, \(ways.joined(separator: " or "))."
        return how + " Open SnugBar again from Applications to get back here."
    }
}

// MARK: - Sections

/// The apps list allows multi-selection (⌘-click, ⇧-click, ⌘A); "Move To…" (button and right-click) moves the
/// selected apps with one settings change, through the same path as each row's own picker.
private struct SectionsSettings: View {
    @ObservedObject var controller: AppController
    @State private var selection: Set<String> = []

    var body: some View {
        let rows = controller.sectionRows
        let bundleIDs = rows.map(\.bundleID)
        let selected = BulkSectionMove.targets(selection: selection, rows: bundleIDs)
        VStack(alignment: .leading, spacing: 10) {
            Picker("New apps go to", selection: setting(controller, \.sections.defaultSection)) {
                ForEach(SnugBarCore.Section.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Text("macOS 27 hides whole apps, so all items of one app are always in the same section. Apple's items, such as the clock and Control Center, are always shown.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(selection: $selection) {
                ForEach(rows, id: \.bundleID) { row in
                    appRow(row)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 120, maxHeight: .infinity)
            .contextMenu(forSelectionType: String.self) { ids in
                let targets = BulkSectionMove.targets(selection: ids, rows: bundleIDs)
                if !targets.isEmpty { moveMenu(targets) }
            }
            .overlay {
                if rows.isEmpty {
                    Text("No apps seen yet. Apps appear here once their items have been visible in the menu bar.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
            .background {
                // ⌘A selects every app. SnugBar has no Edit menu, so the list doesn't get Select All on its own.
                Button("Select All") { selection = Set(bundleIDs) }
                    .keyboardShortcut("a", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            HStack {
                moveMenu(selected)
                    .fixedSize()
                    .disabled(selected.isEmpty)
                Spacer()
            }
            Text("Select several apps with ⌘-click or ⇧-click to move them together.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(20)
        // The split view measures the pane at a tiny width; the wrapped description would then ask for thousands of
        // points of height and push the pane out of the window.
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: bundleIDs) { _, listed in selection.formIntersection(listed) }
    }

    private func appRow(_ row: (bundleID: String, name: String)) -> some View {
        HStack {
            AppIcon(bundleID: row.bundleID).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1)
                Text(row.bundleID).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { controller.settings.sections.section(forBundleID: row.bundleID) },
                set: { controller.setSection($0, for: [row.bundleID]) }
            )) {
                ForEach(SnugBarCore.Section.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    /// "Move To…" (or "Move 3 Apps To…") with the three sections.
    private func moveMenu(_ bundleIDs: [String]) -> some View {
        Menu(BulkSectionMove.title(count: bundleIDs.count)) {
            ForEach(SnugBarCore.Section.allCases, id: \.self) { section in
                Button(section.title) { controller.setSection(section, for: bundleIDs) }
            }
        }
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
        }
    }
}

extension SnugBarCore.Section {
    var title: String {
        switch self {
        case .shown: return "Shown"
        case .hidden: return "Hidden"
        case .alwaysHidden: return "Always Hidden"
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section {
                row("Show or hide hidden items", .toggleHidden)
                row("Show or hide always-hidden items", .toggleAlwaysHidden)
                row("Swap shown and hidden items", .swap)
                row("Search menu bar items", .search)
                row("Open an item by letter", .openByLetter)
                row("Turn Zen mode on or off", .zen)
            } footer: {
                Text("Shortcuts work in every app. Use at least one of ⌃ ⌥ ⌘, or a function key. While Zen mode is on, only its own shortcut works.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !controller.hotkeyFailures.isEmpty {
                Section {
                    ForEach(controller.hotkeyFailures, id: \.self) { Text($0).foregroundStyle(.red) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ action: HotkeyAction) -> some View {
        LabeledContent(title) {
            HStack {
                if !controller.settings.hotkeys.conflicts(for: action).isEmpty {
                    Text("Used twice").font(.caption).foregroundStyle(.orange)
                }
                ShortcutRecorder(hotkey: Binding(
                    get: { controller.settings.hotkeys[action] },
                    set: { value in controller.update { $0.hotkeys[action] = value } }
                ))
            }
        }
    }
}

/// Click, then press a shortcut. Esc cancels; Delete clears.
struct ShortcutRecorder: View {
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggleRecording) {
                Text(recording ? (hint ?? "Type shortcut…") : (hotkey?.description ?? "Record Shortcut"))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            // Always laid out, so buttons line up whether or not a shortcut is set.
            Button { hotkey = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
                .opacity(hotkey != nil && !recording ? 1 : 0)
                .disabled(hotkey == nil || recording)
        }
        .onDisappear(perform: stop)
    }

    private func toggleRecording() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func handle(_ event: NSEvent) {
        let code = Int(event.keyCode)
        let modifiers = Hotkey.Modifiers(eventFlags: event.modifierFlags)
        if modifiers.isEmpty, code == 0x35 { stop(); return } // Esc
        if modifiers.isEmpty, code == 0x33 || code == 0x75 { hotkey = nil; stop(); return } // Delete
        let candidate = Hotkey(keyCode: code, modifiers: modifiers)
        guard candidate.isValidGlobalHotkey else {
            hint = "Add ⌃, ⌥ or ⌘"
            return
        }
        hotkey = candidate
        stop()
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section {
                permission(
                    "Accessibility", granted: controller.accessibilityGranted, required: true,
                    why: "Reads the menu bar and opens items. Without it SnugBar can only hide and show.",
                    action: controller.grantAccessibility
                )
                permission(
                    "Screen Recording", granted: controller.screenRecordingGranted, required: false,
                    why: "Shows pictures of items. Without it SnugBar shows app icons instead.",
                    action: controller.grantScreenRecording
                )
                permission(
                    "Menu bar layout", granted: controller.orderFileGranted, required: false,
                    why: "Lets SnugBar reorder items without moving the pointer. Pick the folder SnugBar suggests.",
                    action: controller.grantOrderFileAccess
                )
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: controller.refreshPermissions)
    }

    private func permission(_ name: String, granted: Bool, required: Bool, why: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : (required ? "exclamationmark.circle.fill" : "circle"))
                .foregroundStyle(granted ? .green : (required ? .orange : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(name + (required ? "" : " (optional)"))
                Text(why).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }
}
