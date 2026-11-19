import AppKit
import SwiftUI

/// Copy for the sync status line, kept apart from the view so it can be tested.
struct SyncStatusText {
    static func describe(_ status: SyncController.Status, now: Date) -> String {
        switch status {
        case .off: "Off"
        case .syncing: "Syncing…"
        case .synced(let date): "Synced \(relative(date, now: now))"
        case .needsFolder: "Can't open the sync folder. Choose it again."
        case .awaitingChoice: "Waiting for your choice"
        case .failed(let message): message
        }
    }

    static func lastSynced(_ date: Date, now: Date) -> String {
        "last synced \(relative(date, now: now))"
    }

    private static func relative(_ date: Date, now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct SyncSettingsTab: View {
    @Environment(SyncController.self) private var controller
    @State private var deviceToRemove: RemoteDevice?
    @State private var removeError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Sync between Macs", isOn: Binding(
                    get: { controller.isEnabled },
                    set: { turnOn in
                        if turnOn { chooseFolder() } else { controller.disable() }
                    }
                ))
                if controller.isEnabled {
                    LabeledContent("Folder") {
                        HStack {
                            Text(controller.folderDisplayPath ?? "None")
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Change…") { chooseFolder() }
                        }
                    }
                    LabeledContent("Status") {
                        HStack {
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(SyncStatusText.describe(controller.status, now: context.date))
                                    .foregroundStyle(statusIsProblem ? .red : .primary)
                            }
                            if controller.status == .needsFolder {
                                Button("Choose…") { chooseFolder() }
                            }
                        }
                    }
                    LabeledContent("Sync now") {
                        Button("Sync Now") { Task { await controller.syncNow() } }
                            .disabled(controller.status == .syncing)
                    }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("In Finder, right-click the folder and choose Keep Downloaded (on macOS 14, turn off Optimize Mac Storage). Don't also sync this folder with Dropbox or OneDrive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if controller.isEnabled {
                Section("Macs in this folder") {
                    LabeledContent(controller.deviceName) { Text("(this Mac)").foregroundStyle(.secondary) }
                    ForEach(controller.devices, id: \.deviceID) { device in
                        LabeledContent(device.deviceName) {
                            HStack {
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text(device.isStale
                                         ? "inactive"
                                         : SyncStatusText.lastSynced(device.exportedAt, now: context.date))
                                        .foregroundStyle(.secondary)
                                }
                                if device.isStale {
                                    Button("Remove") { deviceToRemove = device }
                                }
                            }
                        }
                    }
                    if let removeError {
                        Text(removeError).font(.footnote).foregroundStyle(.red)
                    }
                    ForEach(controller.notes, id: \.self) { note in
                        Text(note).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .alert(firstSyncTitle, isPresented: awaitingChoice) {
            Button("Use This Mac's") { Task { await controller.resolveFirstSync(useThisMac: true) } }
            Button("Use \(otherName)'s") { Task { await controller.resolveFirstSync(useThisMac: false) } }
            Button("Cancel", role: .cancel) { controller.cancelFirstSync() }
        } message: {
            Text(firstSyncMessage)
        }
        .alert("Remove \(deviceToRemove?.deviceName ?? "this Mac") from sync?",
               isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }),
               presenting: deviceToRemove) { device in
            Button("Remove", role: .destructive) {
                do {
                    try controller.removeDevice(device.deviceID)
                    removeError = nil
                } catch {
                    removeError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its file is deleted from the folder. Data on this Mac stays.")
        }
    }

    // MARK: - Status

    private var statusIsProblem: Bool {
        switch controller.status {
        case .failed, .needsFolder: true
        default: false
        }
    }

    // MARK: - First-sync dialog

    private var differences: [SettingDifference] {
        if case .awaitingChoice(let diffs) = controller.status { return diffs }
        return []
    }

    private var awaitingChoice: Binding<Bool> {
        Binding(
            get: { if case .awaitingChoice = controller.status { true } else { false } },
            set: { _ in }
        )
    }

    private var otherName: String {
        let active = controller.devices.filter { !$0.isStale }
        return active.count == 1 ? active[0].deviceName : "the other Macs"
    }

    private var firstSyncTitle: String { "Your settings differ from \(otherName)" }

    private var firstSyncMessage: String {
        differences
            .map { "\($0.label): \($0.here) here, \($0.there) on \(otherName)" }
            .joined(separator: "\n")
    }

    // MARK: - Folder panel

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder in iCloud Drive, e.g. a new folder named TuneNook. Pick the same folder on your other Mac."
        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: icloud.path) { panel.directoryURL = icloud }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.enable(folder: url) }
    }
}
