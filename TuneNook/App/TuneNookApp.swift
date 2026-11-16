import AppKit
import SwiftData
import SwiftUI

@main
struct TuneNookApp: App {
    private let container: ModelContainer
    private let notifications: NotificationService
    private let coordinator: SessionCoordinator
    private let awayMonitor: AwayMonitor
    private let nowPlaying: NowPlayingController
    @State private var engine: TimerEngine
    @State private var radio: RadioPlayer
    @State private var goalStore: GoalStore
    @State private var rewards: RewardStore
    @State private var launchAtLogin = LaunchAtLogin()
    @State private var hotKeys: HotKeyCenter

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
        let rewards = RewardStore()
        let coordinator = SessionCoordinator(
            context: container.mainContext,
            engine: engine,
            goalStore: goalStore,
            rewards: rewards,
            notifications: notifications,
            celebrations: CelebrationCenter(),
            music: MusicDirector(radio: radio)
        )
        coordinator.attach()

        let awayMonitor = AwayMonitor(engine: engine, notifications: notifications)
        awayMonitor.start()
        notifications.onResumeRequested = { [weak engine] in engine?.resume() }
        let nowPlaying = NowPlayingController(radio: radio)
        nowPlaying.start()
        let hotKeys = HotKeyCenter { [weak engine] in engine?.toggle() }

        notifications.requestAuthorization()
        engine.startTicking()

        self.container = container
        self.notifications = notifications
        self.coordinator = coordinator
        self.awayMonitor = awayMonitor
        self.nowPlaying = nowPlaying
        _hotKeys = State(initialValue: hotKeys)
        _engine = State(initialValue: engine)
        _radio = State(initialValue: radio)
        _goalStore = State(initialValue: goalStore)
        _rewards = State(initialValue: rewards)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(engine)
                .environment(radio)
                .environment(goalStore)
                .environment(rewards)
                .modelContainer(container)
        } label: {
            MenuBarLabel(engine: engine, rewards: rewards)
        }
        .menuBarExtraStyle(.window)

        Window("TuneNook", id: WindowID.main) {
            MainView()
                .environment(engine)
                .environment(radio)
                .environment(goalStore)
                .environment(rewards)
                .modelContainer(container)
        }
        .defaultSize(width: 820, height: 560)

        Settings {
            SettingsView()
                .environment(radio)
                .environment(goalStore)
                .environment(rewards)
                .environment(launchAtLogin)
                .environment(hotKeys)
                .modelContainer(container)
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// Brings a window of an `LSUIElement` app to the front.
@MainActor
func activateApp() {
    NSApp.activate()
}
