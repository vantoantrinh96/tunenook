import AppKit
import SwiftUI

/// Click, then press a key combination. Escape cancels.
struct ShortcutRecorder: View {
    @Environment(HotKeyCenter.self) private var hotKeys
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                hotKeys.isRecording ? stop() : start()
            } label: {
                Text(label)
                    .monospaced()
                    .frame(minWidth: 110)
            }
            .help(hotKeys.isRecording ? "Press a combination with ⌘, ⌥ or ⌃. Escape cancels." : "Click to record a new shortcut")
            if hotKeys.shortcut != nil && !hotKeys.isRecording {
                Button {
                    hotKeys.set(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Turn the shortcut off")
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if hotKeys.isRecording { return "Press keys…" }
        return hotKeys.shortcut?.display ?? "Record Shortcut"
    }

    private func start() {
        hotKeys.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == 53 { // Escape
                stop()
            } else if let shortcut = GlobalShortcut(
                keyCode: event.keyCode,
                flags: event.modifierFlags,
                characters: event.charactersIgnoringModifiers
            ) {
                hotKeys.set(shortcut)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if hotKeys.isRecording { hotKeys.isRecording = false }
    }
}
