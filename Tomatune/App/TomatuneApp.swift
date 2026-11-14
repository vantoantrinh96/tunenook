import AppKit
import SwiftData
import SwiftUI

@main
struct TomatuneApp: App {
    private let container: ModelContainer
    private let notifications: NotificationService
    @State private var engine: TimerEngine
    @State private var radio: RadioPlayer

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Topic.self, TodoTask.self, FocusSession.self)
        } catch {
            fatalError("Could not open the Tomatune store: \(error)")
        }
        let engine = TimerEngine()
        let radio = RadioPlayer()
        let notifications = NotificationService()
        let context = container.mainContext

        engine.onSessionEnded = { record in
            context.insert(FocusSession(
                kind: record.kind,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                completed: record.completed,
                task: record.task
            ))
            try? context.save()
        }
        engine.onRunningScheduled = { [weak engine] kind, endsAt in
            notifications.schedulePhaseEnd(kind, at: endsAt, taskTitle: engine?.currentTask?.title)
            if kind == .focus, AppPreferences.autoPlayRadio, !radio.isOn {
                radio.play()
            }
        }
        engine.onRunningCancelled = {
            notifications.cancel()
        }

        notifications.requestAuthorization()
        engine.startTicking()

        self.container = container
        self.notifications = notifications
        _engine = State(initialValue: engine)
        _radio = State(initialValue: radio)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(engine)
                .environment(radio)
                .modelContainer(container)
        } label: {
            MenuBarLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Window("Tomatune", id: WindowID.main) {
            MainView()
                .environment(engine)
                .environment(radio)
                .modelContainer(container)
        }
        .defaultSize(width: 820, height: 560)

        Settings {
            SettingsView()
                .environment(radio)
        }
    }
}

enum WindowID {
    static let main = "main"
}

enum AppPreferences {
    static let autoPlayRadioKey = "radio.autoPlayOnFocus"

    static var autoPlayRadio: Bool {
        UserDefaults.standard.object(forKey: autoPlayRadioKey) as? Bool ?? true
    }
}

/// Brings a window of an `LSUIElement` app to the front.
@MainActor
func activateApp() {
    NSApp.activate()
}
