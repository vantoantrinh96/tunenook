import AppKit
import Foundation
import Observation
import SwiftData
import SystemConfiguration

/// Runs sync passes between this Mac and the shared folder: read the other
/// Macs' files, capture local changes, merge, apply, then publish this Mac's file.
@MainActor
@Observable
final class SyncController {
    enum Status: Equatable {
        case off, syncing, synced(Date), needsFolder, awaitingChoice([SettingDifference]), failed(String)
    }

    private(set) var status: Status = .off
    private(set) var folderDisplayPath: String?
    private(set) var devices: [RemoteDevice] = []
    private(set) var notes: [String] = []

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    static let deviceIDKey = "sync.deviceID"
    static let enabledKey = "sync.enabled"
    /// How long an unchanged device file keeps its `exportedAt` before it is refreshed.
    private static let refreshInterval: TimeInterval = 86_400
    private static let debounceDelay: Duration = .seconds(3)
    private static let timerInterval: TimeInterval = 120

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let goalStore: GoalStore
    @ObservationIgnored private let rewards: RewardStore
    @ObservationIgnored private let engine: TimerEngine
    @ObservationIgnored private let baselineURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let radioIsStopped: () -> Bool
    @ObservationIgnored private let setRadioStation: (String) -> Void
    @ObservationIgnored private let notifyTaskDeleted: (String) -> Void
    @ObservationIgnored private let schedules: Bool
    @ObservationIgnored private let identity: DeviceSnapshot

    @ObservationIgnored private var folderURL: URL?
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private var rerunRequested = false
    /// Set while the user chooses whose settings to keep. Nothing is kept from
    /// that pass: the choice is applied to a fresh capture, so records made
    /// while the dialog is open survive.
    @ObservationIgnored private var awaitingFirstSyncChoice = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    convenience init(context: ModelContext, defaults: UserDefaults, goalStore: GoalStore, rewards: RewardStore,
                     engine: TimerEngine, radio: RadioPlayer?, notifications: NotificationService?,
                     baselineURL: URL, now: @escaping () -> Date = Date.init) {
        self.init(context: context, defaults: defaults, goalStore: goalStore, rewards: rewards, engine: engine,
                  radio: radio, notifications: notifications, baselineURL: baselineURL, now: now,
                  radioIsStopped: nil, schedules: true)
    }

    /// `radioIsStopped` overrides the radio's state (tests); `schedules: false` keeps
    /// passes to explicit `syncNow()` calls.
    init(context: ModelContext, defaults: UserDefaults, goalStore: GoalStore, rewards: RewardStore,
         engine: TimerEngine, radio: RadioPlayer?, notifications: NotificationService?,
         baselineURL: URL, now: @escaping () -> Date, radioIsStopped: (() -> Bool)?, schedules: Bool) {
        self.context = context
        self.defaults = defaults
        self.goalStore = goalStore
        self.rewards = rewards
        self.engine = engine
        self.baselineURL = baselineURL
        self.now = now
        self.schedules = schedules
        if let radio {
            self.radioIsStopped = radioIsStopped ?? { radio.state == .stopped }
            self.setRadioStation = { radio.selectedStationID = $0 }
        } else {
            let setting = SyncedSetting.all.first { $0.key == "radio.selectedStationID" }
            self.radioIsStopped = radioIsStopped ?? { true }
            self.setRadioStation = { setting?.write(.string($0), to: defaults) }
        }
        self.notifyTaskDeleted = { [weak notifications] in notifications?.notifyTaskDeletedElsewhere(taskTitle: $0) }

        let deviceID: String
        if let saved = defaults.string(forKey: Self.deviceIDKey), !saved.isEmpty {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: Self.deviceIDKey)
        }
        var identity = DeviceSnapshot.empty(
            deviceID: deviceID,
            deviceName: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac")
        identity.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        self.identity = identity
    }

    // MARK: - Turning sync on and off

    func start() {
        guard isEnabled else {
            status = .off
            return
        }
        do {
            setFolder(try SyncBookmark.resolve(from: defaults))
        } catch {
            status = .needsFolder
            return
        }
        startScheduling()
        Task { await syncNow() }
    }

    func enable(folder: URL) async {
        do {
            try SyncBookmark.save(folder, in: defaults)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        setFolder(folder)
        awaitingFirstSyncChoice = false
        defaults.set(true, forKey: Self.enabledKey)
        startScheduling()
        await syncNow()
    }

    func resolveFirstSync(useThisMac: Bool) async {
        guard awaitingFirstSyncChoice else { return }
        awaitingFirstSyncChoice = false
        await runPass(firstSyncChoice: useThisMac)
    }

    func cancelFirstSync() {
        awaitingFirstSyncChoice = false
        SyncBookmark.clear(in: defaults)
        defaults.set(false, forKey: Self.enabledKey)
        stopScheduling()
        folderURL = nil
        folderDisplayPath = nil
        status = .off
    }

    func disable() {
        awaitingFirstSyncChoice = false
        defaults.set(false, forKey: Self.enabledKey)
        stopScheduling()
        status = .off
    }

    func removeDevice(_ id: String) throws {
        guard let folder = try existingFolder() else { throw SyncFolderError.needsFolder }
        try folder.remove(deviceID: id)
        devices.removeAll { $0.deviceID == id }
    }

    // MARK: - Passes

    private var canRun: Bool { isEnabled && !awaitingFirstSyncChoice }

    /// Runs a pass now; one requested while another runs makes that one go again.
    func syncNow() async {
        guard canRun else { return }
        if let running = passTask {
            rerunRequested = true
            await running.value
            return
        }
        await runPass(firstSyncChoice: nil)
    }

    private func runPass(firstSyncChoice: Bool?) async {
        while let running = passTask { await running.value }
        let task = Task { [weak self] in
            guard let self else { return }
            var choice = firstSyncChoice
            repeat {
                rerunRequested = false
                await pass(firstSyncChoice: choice)
                choice = nil
            } while rerunRequested && canRun
            passTask = nil
        }
        passTask = task
        await task.value
    }

    /// `firstSyncChoice`: whose differing settings and goals to keep (true: this Mac's).
    private func pass(firstSyncChoice: Bool?) async {
        guard isEnabled else { return }
        status = .syncing
        do {
            guard let folder = try existingFolder() else { throw SyncFolderError.needsFolder }
            let deviceID = identity.deviceID
            let readAt = now()
            let read = try await Task.detached { try folder.read(excluding: deviceID, now: readAt) }.value
            guard isEnabled else { return }
            devices = read.devices
            notes = read.notes

            // From here to the saved baseline nothing suspends, so no edit slips in between.
            let passNow = now()
            let baseline = loadBaseline()
            var local = try capturer.capture(baseline: baseline, now: passNow)
            if baseline == nil, !read.snapshots.isEmpty {
                let remote = SyncMerge.merge(read.snapshots, into: identity, now: passNow)
                if let firstSyncChoice {
                    // Applied to what differs now, which may not be what the dialog showed.
                    local = FirstSync.choose(useThisMac: firstSyncChoice, local: local, remote: remote, now: passNow)
                } else {
                    let diffs = FirstSync.differences(local: local, remote: remote)
                    if !diffs.isEmpty {
                        awaitingFirstSyncChoice = true
                        status = .awaitingChoice(diffs)
                        return
                    }
                }
            }

            let merged = SyncMerge.merge([local] + read.snapshots, into: local, now: passNow.syncMillis)
            isApplying = true
            do {
                try applier.apply(SyncMerge.resolve(merged))
            } catch {
                isApplying = false
                context.rollback()
                throw error
            }
            isApplying = false
            var published = deferringUnappliedSettings(merged: merged, local: local)
            if let baseline, sameContent(published, baseline),
               passNow.timeIntervalSince(baseline.exportedAt) < Self.refreshInterval {
                published.exportedAt = baseline.exportedAt
            }
            try saveBaseline(published)
            clearSettledMerges(in: published, now: passNow)

            let file = published
            let data = try file.encoded()
            try await Task.detached { try folder.writeIfChanged(file, data: data) }.value
            status = .synced(passNow)
        } catch SyncFolderError.needsFolder {
            status = .needsFolder
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Forgets merges whose source tombstone is older than 90 days, or pruned from the baseline.
    private func clearSettledMerges(in baseline: DeviceSnapshot, now: Date) {
        let pending = TopicMerger.pending(in: defaults)
        guard !pending.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        let topics = Dictionary(baseline.topics.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let settled = pending.keys.filter { id in
            guard let topic = topics[id] else { return true }
            return topic.meta.deleted && topic.meta.modifiedAt < cutoff
        }
        TopicMerger.clear(Array(settled), in: defaults)
    }

    /// Settings the applier left alone (the station while the radio plays, an icon
    /// not unlocked yet) keep this Mac's record, so the next capture sees no edit,
    /// the other Mac's value still wins the next merge, and the applier retries.
    private func deferringUnappliedSettings(merged: DeviceSnapshot, local: DeviceSnapshot) -> DeviceSnapshot {
        var result = merged
        for key in ["radio.selectedStationID", "rewards.menuBarIcon"] {
            guard let mergedSetting = merged.settings[key], !mergedSetting.meta.deleted,
                  let localSetting = local.settings[key], currentValue(of: key) != mergedSetting.value
            else { continue }
            result.settings[key] = localSetting
        }
        return result
    }

    private func currentValue(of key: String) -> SyncValue? {
        switch key {
        case "rewards.menuBarIcon": return .string(rewards.selectedIconID)
        default: return SyncedSetting.all.first { $0.key == key }?.read(from: defaults)
        }
    }

    /// Equal apart from `exportedAt`; compared encoded, since merged records come in no set order.
    private func sameContent(_ a: DeviceSnapshot, _ b: DeviceSnapshot) -> Bool {
        var a = a
        a.exportedAt = b.exportedAt
        guard let left = try? a.encoded(), let right = try? b.encoded() else { return false }
        return left == right
    }

    private var capturer: SnapshotCapture {
        SnapshotCapture(context: context, defaults: defaults, goalStore: goalStore, rewards: rewards,
                        identity: identity, mergedTopics: TopicMerger.pending(in: defaults))
    }

    private var applier: SnapshotApplier {
        SnapshotApplier(context: context, defaults: defaults, goalStore: goalStore, rewards: rewards, engine: engine,
                        radioIsStopped: radioIsStopped, setRadioStation: setRadioStation,
                        notifyTaskDeleted: notifyTaskDeleted)
    }

    // MARK: - Folder and baseline

    private func setFolder(_ url: URL) {
        folderURL = url
        folderDisplayPath = Self.displayPath(for: url)
    }

    /// The chosen folder, or nil once it is gone from disk: writing would
    /// otherwise recreate a folder the user deleted.
    private func existingFolder() throws -> SyncFolder? {
        guard let folderURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return SyncFolder(url: folderURL)
    }

    private func loadBaseline() -> DeviceSnapshot? {
        guard let data = try? Data(contentsOf: baselineURL) else { return nil }
        return try? DeviceSnapshot.decode(data)
    }

    private func saveBaseline(_ snapshot: DeviceSnapshot) throws {
        try FileManager.default.createDirectory(at: baselineURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try snapshot.encoded().write(to: baselineURL, options: .atomic)
    }

    static func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let cloudDocs = "/Library/Mobile Documents/com~apple~CloudDocs"
        if let range = path.range(of: cloudDocs) {
            let rest = path[range.upperBound...].split(separator: "/").map(String.init)
            return (["iCloud Drive"] + rest).joined(separator: " › ")
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Scheduling

    private func startScheduling() {
        guard schedules, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { [weak self] _ in
            Self.onMain { self?.scheduleDebouncedPass() }
        })
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            Self.onMain { self?.scheduleDebouncedPass() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { self?.requestPass() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Self.onMain { self?.requestPass() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            Self.onMain { self?.requestPass() }
        }
    }

    /// Runs `body` right away when already on the main thread (so a save made
    /// while applying is seen with `isApplying` still set), otherwise hops there.
    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }

    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []

    private func stopScheduling() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers.removeAll()
        timer?.invalidate()
        timer = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func scheduleDebouncedPass() {
        guard !isApplying, canRun else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private func requestPass() {
        guard canRun else { return }
        Task { await syncNow() }
    }
}

private extension SyncFolder {
    /// Skips the write when the file already holds exactly these bytes, and
    /// never recreates a folder removed since the pass began.
    func writeIfChanged(_ snapshot: DeviceSnapshot, data: Data) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SyncFolderError.needsFolder }
        let file = url.appendingPathComponent("devices/\(snapshot.deviceID).json")
        if let existing = try? Data(contentsOf: file), existing == data { return }
        try write(snapshot)
    }
}
