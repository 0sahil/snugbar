import AppKit
import SnugBarCore

/// "About SnugBar" (feature 91): the standard About panel (app icon, name, version and build from Info.plist, the
/// copyright line) with credits saying what SnugBar is, who owns it, its license and where the source is.
@MainActor
enum AboutPanel {
    static func show(activate: () -> Void) {
        activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let secondary = body.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: ProjectInfo.summary + "\n", attributes: body))
        text.append(NSAttributedString(string: ProjectInfo.ownership + "\n", attributes: secondary))
        text.append(NSAttributedString(string: ProjectInfo.license + " · ", attributes: secondary))
        let link = ProjectInfo.repositoryURL
        text.append(NSAttributedString(string: link.host().map { $0 + link.path() } ?? link.absoluteString,
                                       attributes: body.merging([.link: link]) { $1 }))
        return text
    }
}

/// The app menu. SnugBar is an accessory app, so macOS doesn't draw a menu bar for it; the menu still gives its
/// windows the standard key equivalents (⌘, for Settings, ⌘Q to quit) and holds About and Check for Updates.
@MainActor
enum AppMenu {
    static func install(updater: Updater, about: @escaping () -> Void, settings: @escaping () -> Void) {
        NSApp.mainMenu = build(updater: updater, about: about, settings: settings)
    }

    static func build(updater: Updater, about: @escaping () -> Void, settings: @escaping () -> Void) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let app = NSMenu(title: ProjectInfo.name)
        app.addItem(ClosureMenuItem(title: "About SnugBar", keyEquivalent: "", action: about))
        if updater.isAvailable {
            app.addItem(CheckForUpdatesMenuItem(updater: updater))
        }
        app.addItem(.separator())
        app.addItem(ClosureMenuItem(title: "Settings…", keyEquivalent: ",", action: settings))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit SnugBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
        return main
    }
}

/// "Check for Updates…", enabled while Sparkle can start a check.
final class CheckForUpdatesMenuItem: NSMenuItem, NSMenuItemValidation {
    private let updater: Updater

    @MainActor
    init(updater: Updater) {
        self.updater = updater
        super.init(title: "Check for Updates…", action: #selector(check), keyEquivalent: "")
        target = self
        isEnabled = updater.canCheckForUpdates
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func check() {
        MainActor.assumeIsolated { updater.checkForUpdates() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainActor.assumeIsolated { updater.canCheckForUpdates }
    }
}
