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
}
