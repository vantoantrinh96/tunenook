import Foundation
import SwiftData
import Testing
@testable import TuneNook

@MainActor
final class SyncTestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 60) { now.addTimeInterval(seconds) }
}

@MainActor
final class NoticeLog {
    var items: [SyncAttentionNotice] = []
}

@MainActor
final class RadioFlag {
    var stopped = true
}

/// One simulated Mac: its own store, settings and baseline.
@MainActor
final class SyncTestMac {
    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let goalStore: GoalStore
    let rewards: RewardStore
    let engine: TimerEngine
    let baselineURL: URL
    let controller: SyncController
    let notices = NoticeLog()
    private let radio = RadioFlag()
    var radioStopped: Bool {
        get { radio.stopped }
        set { radio.stopped = newValue }
    }

    init(baselineURL: URL, clock: SyncTestClock, schedules: Bool = false) throws {
        container = try ModelContainer(
            for: Topic.self, TodoTask.self, FocusSession.self,
            configurations: .init(isStoredInMemoryOnly: true))
        context = container.mainContext
        defaults = UserDefaults(suiteName: UUID().uuidString)!
        goalStore = GoalStore(defaults: defaults)
        rewards = RewardStore(defaults: defaults)
        let settings = TimerSettings(autoStartBreaks: false, autoStartFocus: false)
        engine = TimerEngine(clock: { clock.now }, settings: { settings })
        self.baselineURL = baselineURL
        let radio = self.radio
        let notices = self.notices
        controller = SyncController(
            context: context, defaults: defaults, goalStore: goalStore, rewards: rewards, engine: engine,
            radio: nil, notifications: nil, baselineURL: baselineURL, now: { clock.now },
            radioIsStopped: { radio.stopped }, schedules: schedules,
            notifyAttention: { notices.items.append($0) })
    }

    var deviceID: String { defaults.string(forKey: "sync.deviceID") ?? "" }

    func topicNames() throws -> [String] {
        try context.fetch(FetchDescriptor<Topic>()).map(\.name).sorted()
    }

    func sessionCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<FocusSession>())
    }

    @discardableResult
    func addTopic(_ name: String, sessions: Int, at date: Date) throws -> Topic {
        let topic = Topic(name: name, createdAt: date)
        let task = TodoTask(title: "\(name) task", topic: topic, createdAt: date)
        context.insert(topic)
        context.insert(task)
        for i in 0..<sessions {
            let start = date.addingTimeInterval(Double(i) * 1_800)
            context.insert(FocusSession(kind: .focus, startedAt: start, endedAt: start.addingTimeInterval(1_500),
                                        activeSeconds: 1_500, completed: true, task: task))
        }
        try context.save()
        return topic
    }
}

@MainActor
final class SyncControllerTests {
    let root: URL
    let folder: URL
    let clock = SyncTestClock()
    let macA: SyncTestMac
    let macB: SyncTestMac

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SyncControllerTests-\(UUID().uuidString)")
        folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        macA = try SyncTestMac(baselineURL: root.appendingPathComponent("A/sync-baseline.json"), clock: clock)
        macB = try SyncTestMac(baselineURL: root.appendingPathComponent("B/sync-baseline.json"), clock: clock)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func deviceFile(_ mac: SyncTestMac) -> URL {
        folder.appendingPathComponent("devices/\(mac.deviceID).json")
    }

    private func isSynced(_ mac: SyncTestMac) -> Bool {
        if case .synced = mac.controller.status { return true }
        return false
    }

    /// A has "Work" + 2 sessions, B has "Home" + 1 session; both end with everything.
    private func converge() async throws {
        try macA.addTopic("Work", sessions: 2, at: clock.now.addingTimeInterval(-86_400))
        try macB.addTopic("Home", sessions: 1, at: clock.now.addingTimeInterval(-43_200))
        await macA.controller.enable(folder: folder)
        clock.advance()
        await macB.controller.enable(folder: folder)
        clock.advance()
        await macA.controller.syncNow()
        clock.advance()
    }

    @Test func firstMacSyncsWithoutDialog() async throws {
        await macA.controller.enable(folder: folder)
        #expect(isSynced(macA))
        #expect(macA.controller.isEnabled)
        #expect(FileManager.default.fileExists(atPath: deviceFile(macA).path))
        #expect(FileManager.default.fileExists(atPath: macA.baselineURL.path))
    }

    @Test func twoMacsConverge() async throws {
        try await converge()
        #expect(isSynced(macA))
        #expect(isSynced(macB))
        #expect(try macA.topicNames() == ["Home", "Work"])
        #expect(try macB.topicNames() == ["Home", "Work"])
        #expect(try macA.sessionCount() == 3)
        #expect(try macB.sessionCount() == 3)
        #expect(macA.controller.devices.map(\.deviceID) == [macB.deviceID])
        #expect(macB.controller.devices.map(\.deviceID) == [macA.deviceID])
    }

    @Test func secondPassChangesNothing() async throws {
        try await converge()
        await macB.controller.syncNow()
        clock.advance()
        await macA.controller.syncNow()
        let first = try Data(contentsOf: deviceFile(macA))
        let baseline = try Data(contentsOf: macA.baselineURL)
        clock.advance()
        await macA.controller.syncNow()
        #expect(try Data(contentsOf: deviceFile(macA)) == first)
        #expect(try Data(contentsOf: macA.baselineURL) == baseline)
    }

    @Test func syncedMergeRedirectsLateTask() async throws {
        try macA.addTopic("X", sessions: 0, at: clock.now.addingTimeInterval(-86_400))
        try macA.addTopic("Y", sessions: 0, at: clock.now.addingTimeInterval(-80_000))
        await macA.controller.enable(folder: folder)
        clock.advance()
        await macB.controller.enable(folder: folder)
        clock.advance()
        #expect(try macB.topicNames() == ["X", "Y"])

        let x = try macA.context.fetch(FetchDescriptor<Topic>()).first { $0.name == "X" }!
        let y = try macA.context.fetch(FetchDescriptor<Topic>()).first { $0.name == "Y" }!
        try TopicMerger.merge(x, into: y, context: macA.context, defaults: macA.defaults)
        await macA.controller.syncNow()
        clock.advance()

        // B has not synced since; it adds a task to X.
        let bx = try macB.context.fetch(FetchDescriptor<Topic>()).first { $0.name == "X" }!
        macB.context.insert(TodoTask(title: "Late", topic: bx, createdAt: clock.now))
        try macB.context.save()
        await macB.controller.syncNow()
        clock.advance()
        await macA.controller.syncNow()
        clock.advance()
        await macB.controller.syncNow()

        for mac in [macA, macB] {
            #expect(try mac.topicNames() == ["Y"])
            let tasks = try mac.context.fetch(FetchDescriptor<TodoTask>())
            let late = tasks.first { $0.title == "Late" }
            #expect(late?.topic?.name == "Y")
            #expect(tasks.count == 3)
        }
    }

    @Test func editPropagates() async throws {
        try await converge()
        let work = try macA.context.fetch(FetchDescriptor<Topic>()).first { $0.name == "Work" }
        work?.name = "Office"
        try macA.context.save()
        await macA.controller.syncNow()
        clock.advance()
        await macB.controller.syncNow()
        #expect(try macB.topicNames() == ["Home", "Office"])
    }

    @Test func deletePropagatesAndStaysDeleted() async throws {
        try await converge()
        await macB.controller.syncNow()
        let oldBaseline = try Data(contentsOf: macB.baselineURL)

        let home = try macA.context.fetch(FetchDescriptor<Topic>()).first { $0.name == "Home" }
        if let home { macA.context.delete(home) }
        try macA.context.save()
        clock.advance()
        await macA.controller.syncNow()
        clock.advance()
        await macB.controller.syncNow()
        #expect(try macB.topicNames() == ["Work"])

        try oldBaseline.write(to: macB.baselineURL)
        clock.advance()
        await macB.controller.syncNow()
        clock.advance()
        await macA.controller.syncNow()
        #expect(try macB.topicNames() == ["Work"])
        #expect(try macA.topicNames() == ["Work"])
    }

    @Test func differingSettingsAwaitChoice() async throws {
        macA.defaults.set(50, forKey: "timer.focusMinutes")
        macB.defaults.set(25, forKey: "timer.focusMinutes")
        await macA.controller.enable(folder: folder)
        clock.advance()
        await macB.controller.enable(folder: folder)

        #expect(macB.controller.status == .awaitingChoice([
            SettingDifference(label: "Focus length", here: "25 min", there: "50 min"),
        ]))
        #expect(!FileManager.default.fileExists(atPath: deviceFile(macB).path))
        #expect(!FileManager.default.fileExists(atPath: macB.baselineURL.path))

        // Scheduled passes do nothing while awaiting a choice.
        await macB.controller.syncNow()
        #expect(!FileManager.default.fileExists(atPath: deviceFile(macB).path))

        clock.advance()
        await macB.controller.resolveFirstSync(useThisMac: false)
        #expect(isSynced(macB))
        #expect(macB.defaults.integer(forKey: "timer.focusMinutes") == 50)
        #expect(FileManager.default.fileExists(atPath: deviceFile(macB).path))
    }

    @Test func recordsMadeWhileChoosingSurvive() async throws {
        macA.defaults.set(50, forKey: "timer.focusMinutes")
        macB.defaults.set(25, forKey: "timer.focusMinutes")
        try macA.addTopic("Work", sessions: 1, at: clock.now.addingTimeInterval(-3_600))
        await macA.controller.enable(folder: folder)
        clock.advance()
        await macB.controller.enable(folder: folder)
        guard case .awaitingChoice = macB.controller.status else {
            Issue.record("Expected awaitingChoice, got \(macB.controller.status)")
            return
        }

        clock.advance()
        try macB.addTopic("New", sessions: 1, at: clock.now)
        clock.advance()
        await macB.controller.resolveFirstSync(useThisMac: false)
        #expect(isSynced(macB))
        #expect(try macB.topicNames() == ["New", "Work"])
        #expect(try macB.sessionCount() == 2)
        #expect(macB.defaults.integer(forKey: "timer.focusMinutes") == 50)

        clock.advance()
        await macA.controller.syncNow()
        #expect(try macA.topicNames() == ["New", "Work"])
        #expect(try macA.sessionCount() == 2)
        #expect(macA.defaults.integer(forKey: "timer.focusMinutes") == 50)
    }

    @Test func cancelFirstSyncWritesNothing() async throws {
        macA.defaults.set(50, forKey: "timer.focusMinutes")
        await macA.controller.enable(folder: folder)
        clock.advance()
        await macB.controller.enable(folder: folder)
        guard case .awaitingChoice = macB.controller.status else {
            Issue.record("Expected awaitingChoice, got \(macB.controller.status)")
            return
        }
        macB.controller.cancelFirstSync()
        #expect(macB.controller.status == .off)
        #expect(!macB.controller.isEnabled)
        #expect(macB.defaults.data(forKey: SyncBookmark.key) == nil)
        await macB.controller.syncNow()
        #expect(!FileManager.default.fileExists(atPath: deviceFile(macB).path))
        #expect(macB.defaults.integer(forKey: "timer.focusMinutes") != 50)
    }

    @Test func unreadableFolderKeepsLocalData() async throws {
        try await converge()
        try FileManager.default.removeItem(at: folder)
        clock.advance()
        await macA.controller.syncNow()
        switch macA.controller.status {
        case .needsFolder, .failed: break
        default: Issue.record("Expected needsFolder or failed, got \(macA.controller.status)")
        }
        #expect(try macA.topicNames() == ["Home", "Work"])
        #expect(try macA.sessionCount() == 3)
        // The deleted folder is not recreated.
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func deferredRadioStationRetriesAndIsNotOverwritten() async throws {
        try await converge()
        await macB.controller.syncNow()
        clock.advance()

        macA.defaults.set("lofi", forKey: "radio.selectedStationID")
        await macA.controller.syncNow()
        clock.advance()

        macB.radioStopped = false
        await macB.controller.syncNow()
        #expect(macB.defaults.string(forKey: "radio.selectedStationID") == nil)
        let bFile = try DeviceSnapshot.decode(Data(contentsOf: deviceFile(macB)))
        #expect(bFile.settings["radio.selectedStationID"]?.value == .null)
        #expect(bFile.settings["radio.selectedStationID"]?.meta.modifiedAt == .distantPast)

        clock.advance()
        await macA.controller.syncNow()
        #expect(macA.defaults.string(forKey: "radio.selectedStationID") == "lofi")
        let aFile = try DeviceSnapshot.decode(Data(contentsOf: deviceFile(macA)))
        #expect(aFile.settings["radio.selectedStationID"]?.value == .string("lofi"))

        clock.advance()
        macB.radioStopped = true
        await macB.controller.syncNow()
        #expect(macB.defaults.string(forKey: "radio.selectedStationID") == "lofi")
    }

    @Test func disableStopsPasses() async throws {
        await macA.controller.enable(folder: folder)
        macA.controller.disable()
        #expect(macA.controller.status == .off)
        #expect(!macA.controller.isEnabled)
        try macA.addTopic("Later", sessions: 0, at: clock.now)
        clock.advance()
        await macA.controller.syncNow()
        let file = try DeviceSnapshot.decode(Data(contentsOf: deviceFile(macA)))
        #expect(file.topics.isEmpty)
    }

    @Test func removeDeviceDeletesItsFile() async throws {
        try await converge()
        try macA.controller.removeDevice(macB.deviceID)
        #expect(!FileManager.default.fileExists(atPath: deviceFile(macB).path))
        #expect(macA.controller.devices.isEmpty)
    }

    @Test func startWithSchedulingDoesNotCrash() async throws {
        let mac = try SyncTestMac(baselineURL: root.appendingPathComponent("C/sync-baseline.json"), clock: clock,
                              schedules: true)
        mac.controller.start()
        #expect(mac.controller.status == .off)
        await mac.controller.enable(folder: folder)
        #expect(mac.controller.isEnabled)
        mac.controller.disable()
        #expect(mac.controller.status == .off)
    }

    @Test func firstSyncWaitsWhileOtherFileIsIncomplete() async throws {
        macA.defaults.set(50, forKey: "timer.focusMinutes")
        await macA.controller.enable(folder: folder)
        let aFile = deviceFile(macA)
        let good = try Data(contentsOf: aFile)
        try good.prefix(good.count / 2).write(to: aFile)

        clock.advance()
        await macB.controller.enable(folder: folder)
        #expect(macB.controller.status == .waitingForDownload)
        #expect(!FileManager.default.fileExists(atPath: deviceFile(macB).path))
        #expect(!FileManager.default.fileExists(atPath: macB.baselineURL.path))
        #expect(macB.defaults.object(forKey: "timer.focusMinutes") == nil)

        // The next pass, with the file complete, asks the question.
        try good.write(to: aFile)
        clock.advance()
        await macB.controller.syncNow()
        guard case .awaitingChoice = macB.controller.status else {
            Issue.record("Expected awaitingChoice, got \(macB.controller.status)")
            return
        }
    }

    @Test func incompleteFileAfterFirstSyncDoesNotBlock() async throws {
        try await converge()
        let bFile = deviceFile(macB)
        let good = try Data(contentsOf: bFile)
        try good.prefix(good.count / 2).write(to: bFile)
        clock.advance()
        await macA.controller.syncNow()
        #expect(isSynced(macA))
        #expect(try macA.topicNames() == ["Home", "Work"])
    }

    @Test func attentionIsNotifiedOncePerTransition() async throws {
        try await converge()
        try FileManager.default.removeItem(at: folder)
        clock.advance()
        await macA.controller.syncNow()
        #expect(macA.controller.status == .needsFolder)
        clock.advance()
        await macA.controller.syncNow()
        #expect(macA.controller.status == .needsFolder)
        #expect(macA.notices.items.map(\.title) == ["Sync paused"])

        // Back to working, then lost again: a second notice.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        clock.advance()
        await macA.controller.syncNow()
        #expect(isSynced(macA))
        try FileManager.default.removeItem(at: folder)
        clock.advance()
        await macA.controller.syncNow()
        #expect(macA.notices.items.map(\.title) == ["Sync paused", "Sync paused"])
    }

    @Test func awaitingChoiceIsNotified() async throws {
        macA.defaults.set(50, forKey: "timer.focusMinutes")
        await macA.controller.enable(folder: folder)
        clock.advance()
        await macB.controller.enable(folder: folder)
        #expect(macB.notices.items.map(\.title) == ["Choose which settings to keep"])
        #expect(macA.notices.items.isEmpty)
    }

    @Test func enabledStateIsStoredAndPersisted() async throws {
        #expect(!macA.controller.isEnabled)
        await macA.controller.enable(folder: folder)
        #expect(macA.controller.isEnabled)
        #expect(macA.defaults.bool(forKey: SyncController.enabledKey))
        macA.controller.disable()
        #expect(!macA.controller.isEnabled)
        #expect(!macA.defaults.bool(forKey: SyncController.enabledKey))
    }

    @Test func pendingMergeOfLiveTopicIsCleared() async throws {
        let topic = try macA.addTopic("Alive", sessions: 0, at: clock.now.addingTimeInterval(-3_600))
        let other = try macA.addTopic("Other", sessions: 0, at: clock.now.addingTimeInterval(-3_000))
        macA.defaults.set([topic.syncID.uuidString: other.syncID.uuidString], forKey: TopicMerger.defaultsKey)
        await macA.controller.enable(folder: folder)
        #expect(isSynced(macA))
        #expect(TopicMerger.pending(in: macA.defaults).isEmpty)
    }

    @Test func passOverManySessionsIsFast() async throws {
        try macA.addTopic("Big", sessions: 5_000, at: clock.now.addingTimeInterval(-5_000 * 1_800 - 86_400))
        await macA.controller.enable(folder: folder)
        #expect(isSynced(macA))
        clock.advance()
        let baseline = try Data(contentsOf: macA.baselineURL)
        let elapsed = await ContinuousClock().measure { await macA.controller.syncNow() }
        print("SyncController benchmark, pass over 5,000 sessions: \(elapsed)")
        #expect(isSynced(macA))
        #expect(try Data(contentsOf: macA.baselineURL) == baseline)
        #expect(elapsed < .seconds(1))
    }
}
