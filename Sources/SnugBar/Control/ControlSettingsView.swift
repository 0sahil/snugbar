import AppKit
import SnugBarCore
import SwiftUI

/// Settings > Control: the one local server (used by both the command-line tool and AI agents), how agents and the
/// tool connect to it, the access token, and `snugbar://` links (which don't use the server).
struct ControlSettings: View {
    @ObservedObject var controller: AppController
    @ObservedObject var control: ControlSurface
    @State private var portText = ""
    @State private var portError: String?
    @State private var showingInstall = false
    @State private var confirmingRegenerate = false

    private var server: ControlServerSettings { controller.settings.controlServer }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { server.enabled }, set: { control.setEnabled($0) })) {
                    Text("Turn on control server")
                    Text("SnugBar runs one local server. The snugbar command-line tool and AI agents (MCP) both connect through it, so turning it off stops both. Links don’t use it and keep working.")
                }
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort)
                            .disabled(portText == String(server.port))
                    }
                }
                if let portError {
                    Text(portError).font(.callout).foregroundStyle(.red)
                }
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(statusIsError ? .red : .secondary)
                }
            } header: {
                Text("Control server")
            } footer: {
                Text("Only this Mac can connect, and requests from web pages are refused.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Endpoint") {
                    HStack {
                        Text(control.mcpURL)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .fixedSize()
                        Button("Copy") { ControlSurface.copy(control.mcpURL) }
                    }
                }
                SetupText(title: "Claude Code", display: control.claudeCodeLine(mask: true), copy: { control.claudeCodeLine(mask: false) })
                SetupText(title: "Hermes (config.yaml)", display: control.hermesConfig(mask: true), copy: { control.hermesConfig(mask: false) })
                if !server.enabled { serverOffNote }
            } header: {
                Text("AI agents (MCP)")
            } footer: {
                Text("Add SnugBar to an agent with one of these. Copy includes the access token when one is required.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("Install Command-Line Tool…") { showingInstall = true }
                } label: {
                    Text("snugbar")
                    Text("Runs SnugBar’s commands from Terminal, for example “snugbar list”.")
                }
                if !server.enabled { serverOffNote }
            } header: {
                Text("Command-line tool")
            }

            Section {
                Toggle("Require an access token", isOn: Binding(
                    get: { server.requireToken }, set: { control.setRequireToken($0) }
                ))
                if server.requireToken {
                    LabeledContent("Token") {
                        HStack {
                            Text(control.token.map(ControlSurface.masked) ?? "None")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button("Copy Token") { control.copyToken() }
                                .disabled(control.token == nil)
                            Button("Regenerate…") { confirmingRegenerate = true }
                        }
                    }
                }
                if let error = control.tokenError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Access token")
            } footer: {
                Text("Applies to the command-line tool and AI agents alike. The snugbar command reads the token by itself; agents send it as “Authorization: Bearer <token>”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .confirmationDialog("Regenerate the access token?", isPresented: $confirmingRegenerate) {
                Button("Regenerate") { control.regenerateToken() }
            } message: {
                Text("Clients that use the current token, such as AI agents set up with it, stop working until you give them the new one. The snugbar command picks up the new token by itself.")
            }

            Section {
                Text("Apps can control SnugBar with links such as snugbar://expand, without the control server. The first time an app opens a link that changes something, SnugBar asks you.")
                    .font(.callout).foregroundStyle(.secondary)
                let links = controller.settings.urlScheme
                if !links.allowedCallers.isEmpty {
                    LabeledContent("Allowed", value: names(links.allowedCallers))
                }
                if !links.deniedCallers.isEmpty {
                    LabeledContent("Not allowed", value: names(links.deniedCallers))
                }
                HStack {
                    Spacer()
                    Button("Reset") { control.resetLinkAnswers() }
                        .disabled(links.allowedCallers.isEmpty && links.deniedCallers.isEmpty)
                        .help("Forget which apps are allowed; SnugBar asks again.")
                }
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
        .onAppear { portText = String(server.port) }
        .onChange(of: server.port) { _, port in portText = String(port) }
        .sheet(isPresented: $showingInstall) {
            InstallToolSheet(path: control.cliPath)
        }
    }

    private func applyPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        guard let port = Int(trimmed), control.setPort(port) else {
            portError = "Enter a port from \(ControlServerSettings.portRange.lowerBound) to \(ControlServerSettings.portRange.upperBound)."
            return
        }
        portError = nil
        portText = String(port)
    }

    private var serverOffNote: some View {
        Text("The control server is off. Turn it on above to use this.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private var statusText: String {
        switch control.serverState {
        case .off: return "Off"
        case let .starting(port): return "Starting on 127.0.0.1:\(port)…"
        case let .listening(port): return "Listening on 127.0.0.1:\(port)"
        case let .failed(_, message): return message
        }
    }

    private var statusIsError: Bool {
        if case .failed = control.serverState { return true }
        return false
    }

    private func names(_ bundleIDs: [String]) -> String {
        bundleIDs.map { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }.joined(separator: ", ")
    }
}

/// A title, selectable monospaced text and a Copy button.
private struct SetupText: View {
    let title: String
    let display: String
    let copy: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Copy") { ControlSurface.copy(copy()) }
            }
            Text(display)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How to link the `snugbar` tool into the PATH. SnugBar doesn't run these itself.
private struct InstallToolSheet: View {
    let path: String
    @Environment(\.dismiss) private var dismiss

    private var quoted: String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install the Command-Line Tool").font(.headline)
            Text("Link the snugbar tool into a folder on your PATH by running one of these commands in Terminal.")
                .fixedSize(horizontal: false, vertical: true)
            SetupText(title: "For all users, in /usr/local/bin (asks for your password)",
                      display: "sudo ln -sf \(quoted) /usr/local/bin/snugbar",
                      copy: { "sudo ln -sf \(quoted) /usr/local/bin/snugbar" })
            SetupText(title: "Just for you, in ~/.local/bin (that folder must be on your PATH)",
                      display: "mkdir -p ~/.local/bin && ln -sf \(quoted) ~/.local/bin/snugbar",
                      copy: { "mkdir -p ~/.local/bin && ln -sf \(quoted) ~/.local/bin/snugbar" })
            Text("The link points to SnugBar where it is now. Move SnugBar to the Applications folder first if it isn’t there yet.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
