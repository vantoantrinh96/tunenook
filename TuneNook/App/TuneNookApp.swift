import AppKit
import SwiftData
import SwiftUI

@main
struct TuneNookApp: App {
    private let container: ModelContainer
    private let notifications: NotificationService
    @State private var engine: TimerEngine
    @State private var radio: RadioPlayer
    @State private var goalStore: GoalStore

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Topic.self, TodoTask.self, FocusSession.self)
        } catch {
            fatalError("Could not open the TuneNook store: \(error)")
        }
        let engine = TimerEngine()
        let radio = RadioPlayer()
        let notifications = NotificationService()
        let goalStore = GoalStore()
        let context = container.mainContext

        engine.onSessionEnded = { record in
            let wasMet = Self.todayGoalMet(context: context, goalStore: goalStore)
            context.insert(FocusSession(
                kind: record.kind,
                startedAt: record.startedAt,
                endedAt: record.endedAt,
                activeSeconds: record.activeDuration,
                completed: record.completed,
                task: record.task
            ))
            try? context.save()
            if record.kind == .focus, record.completed, !wasMet,
               Self.todayGoalMet(context: context, goalStore: goalStore) {
                let sessions = (try? context.fetch(FetchDescriptor(predicate: FocusSession.completedFocus))) ?? []
                let streak = FocusProgress(sessions: sessions, goalStore: goalStore).streak.current
                notifications.notifyGoalReached(streak: streak)
            }
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
        _goalStore = State(initialValue: goalStore)
    }

    private static func todayGoalMet(context: ModelContext, goalStore: GoalStore) -> Bool {
        let calendar = goalStore.calendar
        let dayStart = calendar.day(for: .now).addingTimeInterval(Double(goalStore.dayStartHour) * 3600)
        let focus = SessionKind.focus.rawValue
        let descriptor = FetchDescriptor<FocusSession>(predicate: #Predicate {
            $0.completed && $0.kindRaw == focus && $0.endedAt >= dayStart
        })
        let sessions = (try? context.fetch(descriptor)) ?? []
        let total = DayTotal(seconds: sessions.reduce(0) { $0 + $1.focusedDuration }, sessions: sessions.count)
        return goalStore.current.isMet(total)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(engine)
                .environment(radio)
                .environment(goalStore)
                .modelContainer(container)
        } label: {
            MenuBarLabel(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Window("TuneNook", id: WindowID.main) {
            MainView()
                .environment(engine)
                .environment(radio)
                .environment(goalStore)
                .modelContainer(container)
        }
        .defaultSize(width: 820, height: 560)

        Settings {
            SettingsView()
                .environment(radio)
                .environment(goalStore)
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
