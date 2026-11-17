import AppKit
import Carbon.HIToolbox
import Observation

/// A key combination that works from any app.
struct GlobalShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, optionKey, …).
    var modifiers: UInt32
    var display: String

    /// ⌃⌥P: P for play/pause, and free in macOS by default.
    static let `default` = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey),
        display: "⌃⌥P"
    )

    init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    /// Reads a shortcut from a key press. Needs ⌘, ⌥ or ⌃, so plain typing never triggers it.
    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        guard !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var carbon = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= controlKey; symbols += "⌃" }
        if flags.contains(.option) { carbon |= optionKey; symbols += "⌥" }
        if flags.contains(.shift) { carbon |= shiftKey; symbols += "⇧" }
        if flags.contains(.command) { carbon |= cmdKey; symbols += "⌘" }
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(carbon)
        self.display = symbols + Self.keyName(keyCode: Int(keyCode), characters: characters)
    }

    static func keyName(keyCode: Int, characters: String?) -> String {
        switch keyCode {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default:
            // F-key codes aren't contiguous, so look them up.
            if let index = functionKeys.firstIndex(of: keyCode) { "F\(index + 1)" } else { characters?.uppercased() ?? "?" }
        }
    }

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}

/// Registers the start/pause shortcut with the system and remembers the user's choice.
/// Carbon hot keys need no Accessibility permission and work in the sandbox.
@MainActor
@Observable
final class HotKeyCenter {
    private(set) var shortcut: GlobalShortcut?
    /// While recording a new shortcut, the old one is released so the key press reaches the recorder.
    var isRecording = false {
        didSet { isRecording ? unregister() : register() }
    }

    @ObservationIgnored private let action: @MainActor () -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var hotKeyRef: EventHotKeyRef?
    @ObservationIgnored private var handlerRef: EventHandlerRef?

    private static let key = "shortcut.toggleTimer"
    private static let signature: OSType = 0x544E_6E6B // "TNnk"

    init(defaults: UserDefaults = .standard, action: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.action = action
        if let data = defaults.data(forKey: Self.key) {
            // An empty value means the user turned the shortcut off.
            shortcut = data.isEmpty ? nil : try? JSONDecoder().decode(GlobalShortcut.self, from: data)
        } else {
            shortcut = .default
        }
        installHandler()
        register()
    }

    func set(_ shortcut: GlobalShortcut?) {
        self.shortcut = shortcut
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: Self.key)
        register()
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                // Hot key events arrive on the main thread's event loop.
                MainActor.assumeIsolated {
                    Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().action()
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func register() {
        unregister()
        guard let shortcut, !isRecording else { return }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
