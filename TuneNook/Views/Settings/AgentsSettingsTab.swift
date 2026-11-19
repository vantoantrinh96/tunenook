import AppKit
import SwiftUI

/// Port text typed in the Agents tab.
@MainActor enum AgentsPortInput {
    /// The port for `text`, or nil unless it is digits only and inside `MCPServerController.portRange`.
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), trimmed.allSatisfy(\.isNumber),
            let port = Int(trimmed), MCPServerController.portRange.contains(port)
        else { return nil }
        return port
    }
}

struct AgentsSettingsTab: View {
    @Environment(MCPServerController.self) private var controller
    @State private var portText = ""
    @State private var portInvalid = false
    @State private var confirmRegenerate = false

    var body: some View {
        let isStarting = controller.status == .starting
        Form {
            Section {
                Toggle("Let AI agents manage TuneNook", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { enabled in Task { await controller.setEnabled(enabled) } }
                ))
                .disabled(isStarting)
                LabeledContent("Status") { statusView }
                LabeledContent("Port") {
                    TextField("Port", text: $portText)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .disabled(isStarting)
                        .onSubmit(applyPort)
                        .onChange(of: portText) { portInvalid = false }
                }
                if portInvalid {
                    Text("Use a port from \(MCPServerController.portRange.lowerBound) to \(MCPServerController.portRange.upperBound).")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if !controller.token.isEmpty {
                    LabeledContent("Token") {
                        HStack {
                            Text(String(repeating: "\u{2022}", count: 12))
                                .foregroundStyle(.secondary)
                            CopyButton("Copy", text: controller.token)
                            Button("Regenerate") { confirmRegenerate = true }
                                .disabled(isStarting)
                        }
                    }
                }
            } header: {
                Text("MCP server")
            } footer: {
                Text("Agents can manage topics, tasks and settings and read your focus history. They can't control the timer or the radio. TuneNook must be running.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !controller.token.isEmpty {
                Section("Connect a client") {
                    LabeledContent("Claude Code") {
                        CopyButton("Copy Command",
                                   text: MCPConnectionSnippets.claudeCodeCommand(port: controller.port, token: controller.token))
                    }
                    LabeledContent("Other clients") {
                        CopyButton("Copy Config",
                                   text: MCPConnectionSnippets.jsonConfig(port: controller.port, token: controller.token))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { portText = String(controller.port) }
        .onChange(of: controller.port) { portText = String(controller.port) }
        .alert("Regenerate the token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { Task { await controller.regenerateToken() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connected agents stop working until you give them the new token.")
        }
    }

    @ViewBuilder private var statusView: some View {
        switch controller.status {
        case .off:
            Text("Off").foregroundStyle(.secondary)
        case .starting:
            Text("Starting\u{2026}").foregroundStyle(.secondary)
        case .running(let port):
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Running on 127.0.0.1:\(port)")
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }

    private func applyPort() {
        guard let port = AgentsPortInput.parse(portText) else {
            portInvalid = true
            return
        }
        portText = String(port)
        Task { await controller.setPort(port) }
    }
}

/// Copies `text` to the pasteboard and shows "Copied" for two seconds.
private struct CopyButton: View {
    let title: String
    let text: String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?

    init(_ title: String, text: String) {
        self.title = title
        self.text = text
    }

    var body: some View {
        HStack {
            if copied {
                Text("Copied").font(.footnote).foregroundStyle(.secondary)
            }
            Button(title) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                reset?.cancel()
                reset = Task {
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { copied = false }
                }
            }
        }
    }
}
