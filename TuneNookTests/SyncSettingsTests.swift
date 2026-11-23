import Foundation
import Testing
@testable import TuneNook

@MainActor @Suite struct SyncSettingsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func describesEachStatus() {
        #expect(SyncStatusText.describe(.off, now: now) == "Off")
        #expect(SyncStatusText.describe(.syncing, now: now) == "Syncing…")
        #expect(SyncStatusText.describe(.needsFolder, now: now) == "Can't open the sync folder. Choose it again.")
        #expect(SyncStatusText.describe(.failed("Disk full"), now: now) == "Disk full")
        let diffs = [SettingDifference(label: "Daily goal", here: "60 min", there: "90 min")]
        #expect(SyncStatusText.describe(.awaitingChoice(diffs), now: now) == "Waiting for your choice")
    }

    @Test func syncedShowsRelativeTime() {
        #expect(SyncStatusText.describe(.synced(now.addingTimeInterval(-30)), now: now) == "Synced just now")
        #expect(SyncStatusText.describe(.synced(now.addingTimeInterval(-300)), now: now) == "Synced 5 minutes ago")
    }

    @Test func lastSyncedUsesRelativeTime() {
        #expect(SyncStatusText.lastSynced(now.addingTimeInterval(-300), now: now) == "last synced 5 minutes ago")
    }

    @Test func describesWaitingForDownload() {
        #expect(SyncStatusText.describe(.waitingForDownload, now: now) == "Waiting for iCloud to download…")
    }

    @Test func useOtherButtonNamesOneMacOrSaysTheirs() {
        #expect(SyncStatusText.useOtherButton(activeDeviceNames: ["Studio"]) == "Use Studio's")
        #expect(SyncStatusText.useOtherButton(activeDeviceNames: ["Studio", "Air"]) == "Use Theirs")
    }

    @Test func onlyStoppedStatesNeedAttention() {
        #expect(SyncController.Status.needsFolder.needsAttention)
        #expect(SyncController.Status.failed("x").needsAttention)
        #expect(SyncController.Status.awaitingChoice([]).needsAttention)
        #expect(!SyncController.Status.off.needsAttention)
        #expect(!SyncController.Status.syncing.needsAttention)
        #expect(!SyncController.Status.waitingForDownload.needsAttention)
        #expect(!SyncController.Status.synced(now).needsAttention)
    }

    @Test func attentionTrackerPostsOncePerTransition() {
        var tracker = SyncAttentionTracker()
        #expect(tracker.update(for: .syncing) == nil)
        #expect(tracker.update(for: .needsFolder) == SyncAttentionNotice(
            title: "Sync paused",
            body: "TuneNook can't open the sync folder. Open Settings → Sync to choose it again."))
        // Every pass goes through .syncing back to the same state: no repeat.
        #expect(tracker.update(for: .syncing) == nil)
        #expect(tracker.update(for: .needsFolder) == nil)
        // A different problem posts again.
        #expect(tracker.update(for: .failed("Disk full")) == SyncAttentionNotice(title: "Sync failed", body: "Disk full"))
        #expect(tracker.update(for: .failed("Other error")) == nil)
        #expect(tracker.update(for: .awaitingChoice([])) == SyncAttentionNotice(
            title: "Choose which settings to keep",
            body: "Your settings differ from another Mac. Open Settings → Sync to choose."))
        // Recovering resets, so the same problem later posts again.
        #expect(tracker.update(for: .synced(now)) == nil)
        #expect(tracker.update(for: .needsFolder)?.title == "Sync paused")
        #expect(tracker.update(for: .off) == nil)
        #expect(tracker.update(for: .needsFolder)?.title == "Sync paused")
    }
}
