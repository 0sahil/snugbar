import AppKit
import Combine
import SnugBarCore

/// The CLI, MCP and URL-scheme control surface of the running app: owns the command router, the HTTP server and the
/// token, follows the `controlServer` settings, and runs `snugbar://` links.
@MainActor
final class ControlSurface: ObservableObject {
    @Published private(set) var serverState: ControlServer.State = .off
    /// The token from the token file (nil when there is none).
    @Published private(set) var token: String?
    @Published private(set) var tokenError: String?

    let tokenStore = TokenStore()
    private let controller: AppController
    private let router: CommandRouter
    private let server: ControlServer
    private var applied: (enabled: Bool, port: Int)?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    private var pendingLinks: [(url: String, caller: Caller)] = []

    struct Caller {
        var bundleID: String?
        var name: String?
    }

    /// - Parameter previewServerState: for an offscreen Settings render only: the server state to show. The surface is
    ///   then never started.
    init(controller: AppController, previewServerState: ControlServer.State? = nil) {
        self.controller = controller
        if let previewServerState { serverState = previewServerState }
        var serverRef: ControlServer?
        let engine = AppControlEngine(controller: controller) {
            let s = controller.settings.controlServer
            return (serverRef?.state.port ?? s.effectivePort, s.requireToken)
        }
        router = CommandRouter(engine: engine)
        let tokenStore = self.tokenStore
        let handler = ControlHTTPHandler(router: router, serverVersion: AppInfo.version) {
            let s = controller.settings.controlServer
            // The file is read for every request, so a regenerated token applies at once. A missing file rejects
            // every request rather than letting them through.
            return .init(port: serverRef?.state.port ?? s.effectivePort, requiredToken: s.requireToken ? (tokenStore.read() ?? "") : nil)
        }
        server = ControlServer(handler: handler)
        serverRef = server
        server.onStateChange = { [weak self] state in self?.serverState = state }
    }

    func start() {
        token = tokenStore.read()
        controller.$settings.map(\.controlServer).removeDuplicates()
            .sink { [weak self] settings in self?.apply(settings) }
            .store(in: &cancellables)
        started = true
        let links = pendingLinks
        pendingLinks = []
        for link in links { open(link.url, caller: link.caller) }
    }

    func stop() {
        server.stop()
        applied = nil
    }

    private func apply(_ settings: ControlServerSettings) {
        if settings.requireToken, token == nil { ensureToken() }
        let next = (enabled: settings.enabled, port: settings.effectivePort)
        if let applied, applied.enabled == next.enabled, applied.port == next.port { return }
        applied = next
        if settings.enabled { server.start(port: settings.effectivePort) } else { server.stop() }
    }

    // MARK: - Settings actions

    func setEnabled(_ on: Bool) {
        controller.update { $0.controlServer.enabled = on }
    }

    /// Returns false when the port is out of range.
    @discardableResult
    func setPort(_ port: Int) -> Bool {
        guard ControlServerSettings.portRange.contains(port) else { return false }
        controller.update { $0.controlServer.port = port }
        return true
    }

    /// Turning the token on creates it when needed. Turning it off keeps the file but stops checking it.
    func setRequireToken(_ on: Bool) {
        if on { ensureToken() }
        controller.update { $0.controlServer.requireToken = on }
    }

    func regenerateToken() {
        do {
            token = try tokenStore.regenerate()
            tokenError = nil
        } catch {
            tokenError = "Couldn't write the token file: \(error.localizedDescription)"
        }
    }

    func copyToken() {
        guard let token = tokenStore.read() ?? token else { return }
        Self.copy(token)
    }

    private func ensureToken() {
        do {
            token = try tokenStore.ensure()
            tokenError = nil
        } catch {
            tokenError = "Couldn't write the token file: \(error.localizedDescription)"
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func resetLinkAnswers() {
        controller.update { $0.urlScheme.reset() }
    }

    // MARK: - snugbar:// links

    /// Runs a `snugbar://` link. Read-only commands just run; others from another app need the user's consent once
    /// per app (every time when the sender can't be identified).
    func open(_ url: String, caller: Caller) {
        guard started else {
            pendingLinks.append((url, caller))
            return
        }
        let request: ControlRequest
        switch ControlURL.parse(url) {
        case let .success(r): request = r
        case let .failure(e):
            NSLog("SnugBar: ignored link %@: %@", url, e.message)
            return
        }
        let decision = URLCallerPolicy.decide(
            command: request.command, callerBundleID: caller.bundleID, ownBundleID: controller.ownBundleID,
            settings: controller.settings.urlScheme
        )
        switch decision {
        case .run:
            run(request, url: url)
        case .deny:
            NSLog("SnugBar: ignored link from %@ (not allowed in Settings): %@", caller.bundleID ?? "?", url)
        case let .ask(remember):
            // After the Apple event has been answered, so the sender isn't left waiting on the dialog.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let allowed = self.confirm(request, url: url, caller: caller, canRemember: remember != nil)
                if let remember { self.controller.update { $0.urlScheme.remember(remember, allowed: allowed) } }
                if allowed { self.run(request, url: url) }
            }
        }
    }

    private func run(_ request: ControlRequest, url: String) {
        Task { @MainActor in
            let response = await router.handle(request)
            if let error = response.error {
                NSLog("SnugBar: link %@ failed: %@", url, error.message)
                NSSound.beep()
            }
        }
    }

    private func confirm(_ request: ControlRequest, url: String, caller: Caller, canRemember: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        let action = ControlURL.describe(request)
        if canRemember {
            let name = caller.name ?? caller.bundleID ?? "An app"
            alert.messageText = "Allow “\(name)” to control SnugBar?"
            alert.informativeText = "\(name) opened a SnugBar link to \(action). If you allow this, \(name) can change your menu bar with SnugBar links from now on. You can change this in SnugBar Settings > Control."
        } else {
            alert.messageText = "Allow this link to control SnugBar?"
            alert.informativeText = "A link asked SnugBar to \(action). SnugBar can't tell which app opened it, so it asks every time.\n\n\(url)"
        }
        // The safe answer is the default, so pressing Return doesn't grant anything.
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Setup text

    var port: Int { controller.settings.controlServer.effectivePort }
    var mcpURL: String { "http://127.0.0.1:\(port)/mcp" }

    /// `claude mcp add …`, with the token header when one is required. `mask` hides the token for display.
    func claudeCodeLine(mask: Bool) -> String {
        var line = "claude mcp add --transport http snugbar \(mcpURL)"
        if let header = authorizationHeader(mask: mask) { line += " --header \"Authorization: \(header)\"" }
        return line
    }

    func hermesConfig(mask: Bool) -> String {
        var text = "mcp_servers:\n  snugbar:\n    url: \(mcpURL)"
        if let header = authorizationHeader(mask: mask) { text += "\n    headers:\n      Authorization: \(header)" }
        return text
    }

    private func authorizationHeader(mask: Bool) -> String? {
        guard controller.settings.controlServer.requireToken else { return nil }
        let value = tokenStore.read() ?? token ?? "<token>"
        return "Bearer " + (mask ? Self.masked(value) : value)
    }

    static func masked(_ token: String) -> String {
        token.count > 8 ? String(token.prefix(4)) + String(repeating: "•", count: 8) : token
    }

    /// The `snugbar` tool inside this app.
    var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/snugbar").path
    }
}
