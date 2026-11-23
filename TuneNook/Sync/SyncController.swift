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
        /// No baseline yet and another Mac's file is still coming down from iCloud.
        case waitingForDownload

        /// Sync has stopped until the user acts.
        var needsAttention: Bool {
            switch self {
            case .needsFolder, .awaitingChoice, .failed: true
            default: false
            }
        }
    }

    private(set) var status: Status = .off {
        didSet {
            if let notice = attention.update(for: status) { notifyAttention(notice) }
        }
    }
    private(set) var folderDisplayPath: String?
    private(set) var devices: [RemoteDevice] = []
    private(set) var notes: [String] = []

    /// This Mac's name as other Macs see it.
    var deviceName: String { identity.deviceName }

    /// Stored so views observe it; persisted under `enabledKey`.
    private(set) var isEnabled: Bool

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
    @ObservationIgnored private let notifyAttention: (SyncAttentionNotice) -> Void
    @ObservationIgnored private var attention = SyncAttentionTracker()
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
                  radioIsStopped: nil, schedules: true, notifyAttention: nil)
    }

    /// `radioIsStopped` overrides the radio's state (tests); `schedules: false` keeps
    /// passes to explicit `syncNow()` calls; `notifyAttention` overrides the
    /// user notification posted when sync stops until the user acts (tests).
    init(context: ModelContext, defaults: UserDefaults, goalStore: GoalStore, rewards: RewardStore,
         engine: TimerEngine, radio: RadioPlayer?, notifications: NotificationService?,
         baselineURL: URL, now: @escaping () -> Date, radioIsStopped: (() -> Bool)?, schedules: Bool,
         notifyAttention: ((SyncAttentionNotice) -> Void)? = nil) {
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
        self.notifyAttention = notifyAttention ?? { [weak notifications] notice in
            notifications?.notifySyncAttention(title: notice.title, body: notice.body)
        }
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)

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
        setEnabled(true)
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
        setEnabled(false)
        stopScheduling()
        folderURL = nil
        folderDisplayPath = nil
        status = .off
    }

    func disable() {
        awaitingFirstSyncChoice = false
        setEnabled(false)
        stopScheduling()
        status = .off
    }

    private func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
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
            // Millisecond time, as every record keeps, for the merges and the first-sync choice alike.
            let passNow = now().syncMillis
            let (baseline, baselineData) = loadBaseline()
            if baseline == nil, read.isIncomplete {
                // Deciding the first sync without the other Mac's file would quietly pick
                // a side later; wait for iCloud and try again on the next pass.
                status = .waitingForDownload
                return
            }
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

            let merged = SyncMerge.merge([local] + read.snapshots, into: local, now: passNow)
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
            // Encoded once, then used to compare, to save the baseline and to write the file.
            var data: Data?
            if let baseline, let baselineData,
               passNow.timeIntervalSince(baseline.exportedAt) < Self.refreshInterval {
                // Unchanged apart from `exportedAt` keeps the old one, so the file stays byte-identical.
                var kept = published
                kept.exportedAt = baseline.exportedAt
                let keptData = try kept.encoded()
                if keptData == baselineData {
                    published = kept
                    data = keptData
                }
            }
            let fileData = try data ?? published.encoded()
            if fileData != baselineData { try saveBaseline(fileData) }
            clearSettledMerges(in: published, now: passNow)

            try await Task.detached { try folder.writeIfChanged(deviceID: deviceID, data: fileData) }.value
            guard isEnabled else { return }
            status = .synced(passNow)
        } catch SyncFolderError.needsFolder {
            status = .needsFolder
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Forgets merges whose source tombstone is older than 90 days, was pruned from
    /// the baseline, or is live again (another Mac's newer edit brought it back).
    private func clearSettledMerges(in baseline: DeviceSnapshot, now: Date) {
        let pending = TopicMerger.pending(in: defaults)
        guard !pending.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        let topics = Dictionary(baseline.topics.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let settled = pending.keys.filter { id in
            guard let topic = topics[id], topic.meta.deleted else { return true }
            return topic.meta.modifiedAt < cutoff
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

    /// The saved baseline and its bytes; both nil when missing or unreadable.
    private func loadBaseline() -> (DeviceSnapshot?, Data?) {
        guard let data = try? Data(contentsOf: baselineURL),
              let snapshot = try? DeviceSnapshot.decode(data) else { return (nil, nil) }
        return (snapshot, data)
    }

    private func saveBaseline(_ data: Data) throws {
        try FileManager.default.createDirectory(at: baselineURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: baselineURL, options: .atomic)
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
    func writeIfChanged(deviceID: String, data: Data) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SyncFolderError.needsFolder }
        let file = url.appendingPathComponent("devices/\(deviceID).json")
        if let existing = try? Data(contentsOf: file), existing == data { return }
        try write(data, deviceID: deviceID)
    }
}

/// A user notification telling the user sync has stopped until they act.
struct SyncAttentionNotice: Equatable, Sendable {
    var title: String
    var body: String
}

/// Decides when to post a `SyncAttentionNotice`: once on entering a state that
/// needs the user, not again on every pass that ends there. A pass shows
/// `.syncing` on the way, which neither posts nor resets.
struct SyncAttentionTracker {
    private enum Kind { case needsFolder, awaitingChoice, failed }
    private var current: Kind?

    mutating func update(for status: SyncController.Status) -> SyncAttentionNotice? {
        let kind: Kind?
        let notice: SyncAttentionNotice?
        switch status {
        case .syncing:
            return nil
        case .needsFolder:
            kind = .needsFolder
            notice = SyncAttentionNotice(
                title: "Sync paused",
                body: "TuneNook can't open the sync folder. Open Settings → Sync to choose it again.")
        case .awaitingChoice:
            kind = .awaitingChoice
            notice = SyncAttentionNotice(
                title: "Choose which settings to keep",
                body: "Your settings differ from another Mac. Open Settings → Sync to choose.")
        case .failed(let message):
            kind = .failed
            notice = SyncAttentionNotice(title: "Sync failed", body: message)
        case .off, .synced, .waitingForDownload:
            kind = nil
            notice = nil
        }
        defer { current = kind }
        return kind == current ? nil : notice
    }
}
