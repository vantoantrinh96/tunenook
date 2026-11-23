# Sync Between Macs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TuneNook keeps topics, tasks, focus history, goals, rewards and non-machine settings the same on every Mac that points at one user-chosen iCloud Drive folder.

**Architecture:** Each Mac keeps its SwiftData store where it is and writes one JSON snapshot, `devices/<deviceID>.json`, to the sync folder. A sync pass reads the other Macs' files, captures local changes by diffing the store and defaults against a locally saved baseline, merges everything record by record (newest `modifiedAt` wins, tombstones included), applies the result back to the store and stores, then saves the merged state as the new baseline and as this Mac's device file. The merge and the topic/task resolution are pure functions; IO and scheduling live in a `@MainActor @Observable SyncController`.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Foundation (`NSFileCoordinator`, security-scoped bookmarks), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-19-icloud-sync-design.md`

## Global Constraints

- macOS 14+, Apple silicon, Swift 6. Edit `project.yml`, never the `.xcodeproj`, `Info.plist` or entitlements; run `xcodegen generate` after editing it.
- Work on branch `feat/icloud-sync` (already created from `main`, holds the spec).
- No CloudKit, no iCloud entitlement, no new packages.
- The SwiftData store never moves and is never opened from the sync folder.
- This Mac writes only `devices/<its deviceID>.json`. It never writes or rewrites another Mac's file (the one exception: Settings → **Remove** on a stale device deletes that file).
- Data access on the main actor through `container.mainContext`, `try context.save()` after every write.
- `formatVersion` is `1`. Tombstone window and stale-device window are both **90 days**. Poll interval **120 s**, change debounce **3 s**.
- Synced settings keys (exactly these): `timer.focusMinutes`, `timer.shortBreakMinutes`, `timer.longBreakMinutes`, `timer.longBreakInterval`, `timer.autoStartBreaks`, `timer.autoStartFocus`, `away.pauseOnLock`, `away.idleMinutes`, `music.breakAction`, `music.breakStationID`, `radio.selectedStationID`, `celebrations.level`, `goals.dayStartHour`, `rewards.menuBarIcon`. Goal history and unlocked icons sync separately. Nothing else syncs (no `mcp.*`, shortcut, login item, updater keys, `estimateRange`).
- Sync never calls `TimerEngine.abandon()`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), `@testable import TuneNook`, one suite per file in `TuneNookTests/`, in-memory `ModelContainer(for: Topic.self, TodoTask.self, FocusSession.self, configurations: .init(isStoredInMemoryOnly: true))`, `UserDefaults(suiteName: UUID().uuidString)!`, temp directories under `FileManager.default.temporaryDirectory`.
- Test command (`<Suite>` is the struct name):
  `xcodegen generate && xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build test -only-testing:TuneNookTests/<Suite>`
- Commit messages follow Conventional Commits and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

**Deviation from the spec, allowed by its "left to the builder" list:** `modifiedAt` lives only in the snapshot/baseline, not on the SwiftData models. Models get only `syncID`. Change detection is baseline diff, so no writer (views, `SessionCoordinator`, MCP tools) changes. The "task deleted" notification says "another Mac" rather than the device's name, since the winning tombstone's device is only an ID.

## Review Focus

1. **Migrated rows share one UUID.** SwiftData lightweight migration can evaluate a property default once, giving every existing row the same `syncID`. Expected: after launch every row's `syncID` is unique and nothing is lost. (Task 1, `backfillGivesDuplicatesFreshIDs`)
2. **Echo loops.** A pass that applies remote changes must not see its own writes (store rows, defaults, `GoalStore`, `RewardStore`) as local edits on the next pass. Expected: two passes in a row with no user action produce a byte-identical device file. (Tasks 5, 8: `captureAfterApplyIsUnchanged`, `secondPassChangesNothing`)
3. **A device file iCloud is still writing** (truncated or empty JSON). Expected: that device is skipped this pass with a note, local data untouched, picked up next pass. (Task 7, `truncatedFileIsSkipped`)
4. **An evicted device file** (`devices/.X.json.icloud` placeholder). Expected: download requested, device not treated as gone, its records not deleted. (Task 7, `placeholderRequestsDownload`)
5. **Remote radio station change while music plays.** Expected: the station doesn't switch mid-play; it applies once the radio is stopped (next pass). (Task 6, `radioStationNotChangedWhilePlaying`)

---

## File structure

| File | Responsibility |
|---|---|
| `TuneNook/Models/Topic.swift`, `TodoTask.swift`, `FocusSession.swift` | add `syncID: UUID` |
| `TuneNook/Sync/SyncIDBackfill.swift` | give duplicate/missing `syncID`s fresh UUIDs at launch |
| `TuneNook/Sync/SyncSnapshot.swift` | Codable snapshot + record types, `SyncValue`, `SyncedSetting` table |
| `TuneNook/Sync/SyncMerge.swift` | pure: merge snapshots, prune tombstones, resolve to what the store should hold |
| `TuneNook/Sync/SnapshotCapture.swift` | read store/defaults/stores → snapshot, diffing against the baseline |
| `TuneNook/Sync/SnapshotApplier.swift` | write a resolved state into store/defaults/stores |
| `TuneNook/Sync/SyncFolder.swift` | bookmark, read/write/delete device files, eviction, format check |
| `TuneNook/Sync/FirstSync.swift` | pure: settings/goal differences at first sync, applying the choice |
| `TuneNook/Sync/SyncController.swift` | on/off, passes, scheduling, status, device list |
| `TuneNook/Sync/TopicMerger.swift` | merge one topic into another, record `mergedInto` |
| `TuneNook/Views/Settings/SyncSettingsTab.swift` | Sync tab + first-sync dialog |
| `TuneNook/Views/Main/MergeTopicSheet.swift` | pick a target topic and confirm |
| `TuneNook/Progress/DailyGoal.swift`, `Rewards/Rewards.swift`, `Notifications/NotificationService.swift`, `App/TuneNookApp.swift`, `Views/Main/TopicSidebar.swift`, `Views/Settings/SettingsView.swift`, `project.yml`, `README.md` | small hooks listed per task |

---

### Task 1: Stable IDs on the models

**Files:**
- Modify: `TuneNook/Models/Topic.swift`, `TuneNook/Models/TodoTask.swift`, `TuneNook/Models/FocusSession.swift`
- Create: `TuneNook/Sync/SyncIDBackfill.swift`
- Modify: `TuneNook/App/TuneNookApp.swift` (call backfill right after the container opens)
- Test: `TuneNookTests/SyncIDBackfillTests.swift`

**Interfaces:**
- Produces: `var syncID: UUID = UUID()` on `Topic`, `TodoTask`, `FocusSession`; `enum SyncIDBackfill { @MainActor static func run(in context: ModelContext) throws -> Int }` (returns how many rows got a new ID).

- [ ] **Step 1: Write the failing tests** in `SyncIDBackfillTests`:
  - `newRowsGetDistinctIDs`: insert 2 topics, 2 tasks, 2 sessions; all 6 `syncID`s distinct.
  - `backfillGivesDuplicatesFreshIDs`: insert 3 topics, set all their `syncID` to one fixed UUID, plus 2 sessions sharing another; `run` returns 4 (first of each group keeps its ID), afterwards all `syncID`s distinct and row counts unchanged.
  - `backfillIsNoOpWhenUnique`: `run` returns 0 on unique rows.
- [ ] **Step 2: Run** `SyncIDBackfillTests`. Expected: FAIL, `syncID` not defined.
- [ ] **Step 3: Implement.** Add the property to the three models. `SyncIDBackfill.run` fetches each model, keeps the first row per `syncID` (sorted by `createdAt`/`startedAt`), assigns `UUID()` to the rest, saves if anything changed. Call it in `TuneNookApp.init` after the `ModelContainer` is created (`try? SyncIDBackfill.run(in: container.mainContext)`).
- [ ] **Step 4: Run** `SyncIDBackfillTests`, then the full suite. Expected: PASS (existing tests unaffected).
- [ ] **Step 5: Commit** `feat(sync): stable sync IDs on topics, tasks and sessions`.

### Task 2: Snapshot format

**Files:**
- Create: `TuneNook/Sync/SyncSnapshot.swift`
- Test: `TuneNookTests/SyncSnapshotTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum SyncValue: Codable, Equatable, Sendable { case int(Int), bool(Bool), string(String), null }  // encodes as a bare JSON primitive
  struct SyncMeta: Codable, Equatable, Sendable { var modifiedAt: Date; var modifiedBy: String; var deleted: Bool }
  struct SyncTopic:   Codable, Equatable, Sendable { var id: UUID; var meta: SyncMeta; var name: String; var colorHex: String; var createdAt: Date; var deadline: Date?; var mergedInto: UUID? }
  struct SyncTask:    Codable, Equatable, Sendable { var id: UUID; var meta: SyncMeta; var title: String; var estimatedSessions: Int; var isDone: Bool; var createdAt: Date; var completedAt: Date?; var topicID: UUID? }
  struct SyncSession: Codable, Equatable, Sendable { var id: UUID; var meta: SyncMeta; var kind: String; var startedAt: Date; var endedAt: Date; var activeSeconds: Double; var completed: Bool; var taskID: UUID? }
  struct SyncSetting: Codable, Equatable, Sendable { var value: SyncValue; var meta: SyncMeta }
  struct SyncGoal:    Codable, Equatable, Sendable { var day: Date; var meta: SyncMeta; var kind: String; var target: Int }
  struct DeviceSnapshot: Codable, Equatable, Sendable {
      static let currentFormat = 1
      var formatVersion: Int; var deviceID: String; var deviceName: String; var appVersion: String; var exportedAt: Date
      var topics: [SyncTopic]; var tasks: [SyncTask]; var sessions: [SyncSession]
      var settings: [String: SyncSetting]; var goals: [SyncGoal]; var unlockedIcons: [String]
      static func empty(deviceID: String, deviceName: String) -> DeviceSnapshot
      func encoded() throws -> Data        // ISO-8601 dates with fractional seconds, sorted keys, records sorted by id/day
      static func decode(_ data: Data) throws -> DeviceSnapshot
  }
  struct SyncedSetting: Sendable { let key: String; let defaultValue: SyncValue
      static let all: [SyncedSetting]      // the 14 keys from Global Constraints, defaults: 25, 5, 15, 4, true, false, true, 0, "lowerVolume", null, null, "milestones", 0, "note"
      func read(from: UserDefaults) -> SyncValue   // missing key → defaultValue
      func write(_: SyncValue, to: UserDefaults)  // .null → removeObject
  }
  extension SyncMeta { func wins(over other: SyncMeta) -> Bool }  // newer modifiedAt, tie → larger modifiedBy
  ```
  Each record type also gets `func sameContent(as other: Self) -> Bool` (all fields except `meta`; `SyncTopic` also ignores `mergedInto`).

- [ ] **Step 1: Write the failing tests:**
  - `roundTripsThroughJSON`: a snapshot with one of each record, a `.null` setting and a goal → `decode(encoded())` equals the original.
  - `encodingIsDeterministic`: same snapshot with records in shuffled order → identical `Data`.
  - `syncValueIsBarePrimitive`: `["a": .int(3), "b": .null]` encodes to `{"a":3,"b":null}`.
  - `winsUsesTimeThenDevice`: later `modifiedAt` wins; equal times → `"B"` beats `"A"`; a meta never wins over itself.
  - `missingSettingReadsDefault`: empty defaults → `timer.focusMinutes` reads `.int(25)`, `music.breakStationID` reads `.null`.
- [ ] **Step 2: Run** `SyncSnapshotTests`. Expected: FAIL, types not defined.
- [ ] **Step 3: Implement** the types above in `SyncSnapshot.swift`.
- [ ] **Step 4: Run** `SyncSnapshotTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(sync): device snapshot format`.

### Task 3: Merge and prune

**Files:**
- Create: `TuneNook/Sync/SyncMerge.swift`
- Test: `TuneNookTests/SyncMergeTests.swift`

**Interfaces:**
- Consumes: Task 2 types.
- Produces: `enum SyncMerge { static let tombstoneWindow: TimeInterval = 90 * 86_400; static func merge(_ snapshots: [DeviceSnapshot], into identity: DeviceSnapshot, now: Date) -> DeviceSnapshot }` — returns a snapshot with `identity`'s `deviceID`/`deviceName`/`appVersion`, `exportedAt = now`, `formatVersion = 1`.

Rules: per record id (goal key = `day`, setting key = key), keep the record whose `meta.wins(over:)` the others; then drop records with `meta.deleted && now - modifiedAt > tombstoneWindow`; `unlockedIcons` = sorted union.

- [ ] **Step 1: Write the failing tests:**
  - `newerEditWins`, `newerDeleteBeatsOlderEdit`, `newerEditBeatsOlderDelete` (topic records across two snapshots).
  - `tieBreaksOnDeviceID`: same `modifiedAt`, `modifiedBy` "A" vs "B" → B's content, regardless of input order.
  - `recordsFromOneSideAreKept`: disjoint topics/tasks/sessions → union.
  - `settingsMergePerKey`: A newer on `timer.focusMinutes`, B newer on `away.idleMinutes` → result takes each.
  - `goalsMergePerDay`: A has day 10, B has day 12 → both; both have day 12 → newer wins.
  - `iconsAreUnioned`: `["note","timer"]` + `["note","flame"]` → `["flame","note","timer"]`.
  - `oldTombstonesArePruned`: tombstone 91 days old dropped; 89 days old kept; live record 200 days old kept.
- [ ] **Step 2: Run** `SyncMergeTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `SyncMerge.merge`.
- [ ] **Step 4: Run** `SyncMergeTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(sync): merge device snapshots`.

### Task 4: Resolve what the store should hold

**Files:**
- Modify: `TuneNook/Sync/SyncMerge.swift`
- Test: `TuneNookTests/SyncResolveTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct ResolvedState: Equatable, Sendable {
      var topics: [SyncTopic]; var tasks: [SyncTask]; var sessions: [SyncSession]   // live only, tasks' topicID redirected, sessions' taskID nil if task not live
      var settings: [String: SyncValue]; var goals: [SyncGoal]                         // live goals only, sorted by day
      var unlockedIcons: Set<String>
  }
  extension SyncMerge { static func resolve(_ snapshot: DeviceSnapshot) -> ResolvedState }
  ```

Rules (from spec "Merge rule"): a task's `topicID` follows `mergedInto` chains (stop on cycles or after 16 hops; a cycle counts as deleted). If the final topic is live → task in that topic. If it is a tombstone without `mergedInto` → task dropped (cascade). If it is unknown (not in the snapshot at all) → task held back (not in `tasks`). Tasks with `topicID == nil` are dropped. A session keeps `taskID` only if that task is in the resolved `tasks`.

- [ ] **Step 1: Write the failing tests:**
  - `taskInMergedTopicFollowsTarget`: topic X tombstone `mergedInto: Y`, Y live, task in X → resolved task `topicID == Y`.
  - `taskAddedOfflineToMergedTopicFollowsTarget`: same as above but the task's `modifiedAt` is newer than X's tombstone → still in Y.
  - `mergeChainIsFollowed`: X→Y→Z, Z live → task in Z.
  - `mergeCycleCountsAsDeleted`: X→Y→X → task dropped.
  - `taskInDeletedTopicIsDropped`: X tombstone, no `mergedInto`, task edited after → dropped.
  - `taskWithUnknownTopicIsHeldBack`: not in `tasks`, and not counted as deleted (its session keeps nothing but the session itself stays).
  - `sessionOfDroppedTaskLosesTask`: session in `sessions` with `taskID == nil`.
  - `tombstonesAreNotResolved`: deleted topics/tasks/sessions/goals absent.
- [ ] **Step 2: Run** `SyncResolveTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `resolve`.
- [ ] **Step 4: Run** `SyncResolveTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(sync): resolve merged state for the store`.

### Task 5: Capture local changes

**Files:**
- Create: `TuneNook/Sync/SnapshotCapture.swift`
- Modify: `TuneNook/Progress/DailyGoal.swift` (expose entries), `TuneNook/Rewards/Rewards.swift` (nothing new to read; `unlockedIDs` is already public)
- Test: `TuneNookTests/SnapshotCaptureTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  ```swift
  @MainActor struct SnapshotCapture {
      let context: ModelContext; let defaults: UserDefaults; let goalStore: GoalStore; let rewards: RewardStore
      let identity: DeviceSnapshot                       // deviceID/name/appVersion, records ignored
      let mergedTopics: [UUID: UUID]                     // source syncID → target syncID, from TopicMerger (Task 9)
      func capture(baseline: DeviceSnapshot?, now: Date) throws -> DeviceSnapshot
  }
  // GoalHistory gains: init(entries: [GoalHistory.Entry]); `entries` stays private(set).
  ```

Algorithm: let `seen = baseline.map(SyncMerge.resolve)`. For every store row / synced setting / goal entry / unlocked icon, build its record. If `seen` has the same id with `sameContent` (compare against the **resolved** form, so redirected `topicID`s and nulled `taskID`s don't count as edits), copy the baseline's raw record unchanged; otherwise stamp `SyncMeta(modifiedAt: baseline == nil ? .distantPast : now, modifiedBy: identity.deviceID, deleted: false)`. For every id live in `seen` but missing locally, emit the baseline record as a tombstone stamped `now` (topics: `mergedInto = mergedTopics[id]`). Carry every baseline record that isn't in `seen` (tombstones, held-back and cascaded tasks) unchanged. Goal entries are keyed by `effectiveFrom`. Settings come from `SyncedSetting.all`, except `goals.dayStartHour` read from `goalStore.dayStartHour` and `rewards.menuBarIcon` from `rewards.selectedIconID`.

- [ ] **Step 1: Write the failing tests:**
  - `firstCaptureStampsDistantPast`: no baseline, 1 topic/task/session, goal set, setting changed → all records `.distantPast`, `modifiedBy == identity.deviceID`.
  - `unchangedRowsKeepBaselineMeta`: capture, then capture again with the first result as baseline → equal snapshots.
  - `editedRowIsStampedNow`: rename the topic → only that topic has `modifiedAt == now`.
  - `deletedRowBecomesTombstone`: delete a task → tombstone with `modifiedAt == now`.
  - `mergedTopicTombstoneCarriesTarget`: delete topic X with `mergedTopics = [X: Y]` → tombstone `mergedInto == Y`.
  - `changedSettingIsStamped`: set `timer.focusMinutes` to 50 in defaults → only that setting stamped `now`.
  - `removedGoalEntryBecomesTombstone`: baseline has goals on day 10 and 12; `goalStore.setGoal` on day 10 again (removes 12) → day 12 tombstone.
  - `heldBackTaskIsCarried`: baseline holds a task whose topic is unknown; capture keeps it unchanged and doesn't tombstone it.
  - `captureAfterApplyIsUnchanged`: build a merged snapshot whose resolved form differs from the raw (a task in a merged-away topic, a session of a dropped task), apply it with `SnapshotApplier` (Task 6; add this test in Task 6, Step 1), capture with that snapshot as baseline → equal to the baseline. **(Review Focus 2)**
- [ ] **Step 2: Run** `SnapshotCaptureTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `SnapshotCapture.capture` and `GoalHistory.init(entries:)`.
- [ ] **Step 4: Run** `SnapshotCaptureTests`. Expected: PASS (except the test deferred to Task 6).
- [ ] **Step 5: Commit** `feat(sync): capture local changes against a baseline`.

### Task 6: Apply the resolved state

**Files:**
- Create: `TuneNook/Sync/SnapshotApplier.swift`
- Modify: `TuneNook/Progress/DailyGoal.swift`, `TuneNook/Rewards/Rewards.swift`, `TuneNook/Notifications/NotificationService.swift`
- Test: `TuneNookTests/SnapshotApplierTests.swift` (+ the deferred capture test in `SnapshotCaptureTests`)

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces:
  ```swift
  @MainActor struct SnapshotApplier {
      let context: ModelContext; let defaults: UserDefaults; let goalStore: GoalStore; let rewards: RewardStore
      let engine: TimerEngine
      let radioIsStopped: () -> Bool
      let setRadioStation: (String) -> Void
      let notifyTaskDeleted: (_ taskTitle: String) -> Void
      func apply(_ state: ResolvedState) throws
  }
  // GoalStore: func replaceHistory(_ history: GoalHistory)          (writes through like setGoal)
  // RewardStore: func mergeUnlocked(_ ids: Set<String>)             (union, persists)
  // NotificationService: func notifyTaskDeletedElsewhere(taskTitle: String)
  //   title "Task deleted on another Mac", body "“<title>” was deleted on another Mac. Your session keeps running without a task."
  ```

Order: upsert topics → upsert tasks (set `topic`) → upsert sessions (set `task`) → delete sessions, then tasks, then topics not in `state` → save. Only assign a property when the value differs (avoids no-op saves). If a task being deleted is `engine.currentTask`: set `engine.currentTask = nil` first and call `notifyTaskDeleted` when `engine.isActive`. Settings: `goals.dayStartHour` → `goalStore.dayStartHour`; `rewards.menuBarIcon` → after `mergeUnlocked`, `rewards.select` if unlocked; `radio.selectedStationID` → `setRadioStation` only if `radioIsStopped()`, else skip (next pass retries); all others → `SyncedSetting.write` only when the current value differs. Goals → `replaceHistory` only when different.

- [ ] **Step 1: Write the failing tests:**
  - `insertsUpdatesAndDeletes`: store has topics A, B; state has A renamed and new C, no B → store has A (renamed), C.
  - `movesTaskBeforeDeletingTopic`: task in X, state has it in Y and no X → task survives in Y.
  - `runningTaskDeletedKeepsTimer`: engine started on task T, state lacks T → `engine.isActive`, `engine.currentTask == nil`, notify called once with T's title, store has T's sessions with no task.
  - `settingsWrittenOnlyWhenDifferent`: count `UserDefaults.didChangeNotification` for an unchanged state → 0.
  - `goalHistoryReplaced`, `iconsUnionedAndSelected` (selected icon applied only if unlocked).
  - `radioStationNotChangedWhilePlaying`: `radioIsStopped` false → `setRadioStation` not called; true → called with the value. **(Review Focus 5)**
  - In `SnapshotCaptureTests`: `captureAfterApplyIsUnchanged` (described in Task 5). **(Review Focus 2)**
- [ ] **Step 2: Run** `SnapshotApplierTests` and `SnapshotCaptureTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the applier and the three small additions.
- [ ] **Step 4: Run** both suites. Expected: PASS.
- [ ] **Step 5: Commit** `feat(sync): apply merged state to the store and settings`.

### Task 7: Sync folder

**Files:**
- Create: `TuneNook/Sync/SyncFolder.swift`
- Modify: `project.yml` (entitlements `com.apple.security.files.user-selected.read-write: true`, `com.apple.security.files.bookmarks.app-scope: true`)
- Test: `TuneNookTests/SyncFolderTests.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces:
  ```swift
  struct RemoteDevice: Equatable, Sendable { var deviceID: String; var deviceName: String; var exportedAt: Date; var isStale: Bool }
  struct FolderRead: Sendable {
      var snapshots: [DeviceSnapshot]          // active (not stale), other devices only
      var devices: [RemoteDevice]              // every other device seen, stale included
      var notes: [String]                      // user-facing, see copy below
  }
  struct SyncFolder: Sendable {
      let url: URL
      var startDownload: @Sendable (URL) -> Void = { try? FileManager.default.startDownloadingUbiquitousItem(at: $0) }
      static let staleWindow: TimeInterval = 90 * 86_400
      func read(excluding deviceID: String, now: Date) throws -> FolderRead
      func write(_ snapshot: DeviceSnapshot) throws          // devices/<id>.json, coordinated, atomic
      func remove(deviceID: String) throws
  }
  enum SyncBookmark {           // persisted under defaults key "sync.folderBookmark"
      static func save(_ url: URL, in defaults: UserDefaults) throws
      static func resolve(from defaults: UserDefaults) throws -> URL   // starts security-scoped access; refreshes stale bookmark data; throws SyncFolderError.needsFolder if it can't
      static func clear(in defaults: UserDefaults)
  }
  enum SyncFolderError: Error, Equatable { case needsFolder }
  ```
  Notes copy: unreadable file → `"Couldn't read <file name>. It will be tried again."`; newer format → `"<device name> uses a newer TuneNook. Update TuneNook on this Mac to sync with it."` (device name from the file if decodable, else the file name); iCloud placeholder → no note; folder under `~/Library/Mobile Documents` while `FileManager.default.ubiquityIdentityToken == nil` → `"iCloud Drive is off or signed out on this Mac."`

Reading: list `devices/`; for `.<name>.json.icloud` call `FileManager.default.startDownloadingUbiquitousItem(at: devices/<name>.json)` and skip; decode each `*.json` under `NSFileCoordinator` read; decode `formatVersion` first and skip `> DeviceSnapshot.currentFormat`; mark stale when `now - exportedAt > staleWindow`. A missing `devices/` folder reads as empty.

- [ ] **Step 1: Write the failing tests** (temp directory as the folder):
  - `writesAndReadsBack`: write snapshots for "A" and "B"; `read(excluding: "A")` returns only B.
  - `staleDeviceIsListedButNotMerged`: B exported 91 days ago → in `devices` with `isStale`, not in `snapshots`.
  - `truncatedFileIsSkipped`: write half of B's JSON → not in `snapshots`, one note, no throw. **(Review Focus 3)**
  - `newerFormatIsSkippedWithNote`: `formatVersion: 2` → skipped, note mentions the device name.
  - `placeholderRequestsDownload`: create `devices/.B.json.icloud` → no throw, no note, B not in `snapshots` (download call is a no-op outside iCloud; assert via an injected `startDownload: (URL) -> Void` closure on `SyncFolder` that it was called with `devices/B.json`). **(Review Focus 4)**
  - `removeDeletesOnlyThatFile`.
  - `missingDevicesFolderReadsEmpty`: a fresh folder → no snapshots, no notes, no throw.
  - `writeIsAtomic`: write twice; no temp files left in `devices/`.
- [ ] **Step 2: Run** `SyncFolderTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `SyncFolder` and `SyncBookmark`; add the entitlements to `project.yml`.
- [ ] **Step 4: Run** `SyncFolderTests`. Expected: PASS. Run `xcodegen generate` and build the app; `codesign -d --entitlements - build/Build/Products/Debug/TuneNook.app` lists both new entitlements.
- [ ] **Step 5: Commit** `feat(sync): read and write device files in the sync folder`.

### Task 8: Sync controller and first sync

**Files:**
- Create: `TuneNook/Sync/FirstSync.swift`, `TuneNook/Sync/SyncController.swift`
- Modify: `TuneNook/App/TuneNookApp.swift` (create, put in Settings environment, start)
- Test: `TuneNookTests/FirstSyncTests.swift`, `TuneNookTests/SyncControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 2–7.
- Produces:
  ```swift
  struct SettingDifference: Equatable, Sendable { var label: String; var here: String; var there: String }   // e.g. "Focus length", "50 min", "25 min"
  enum FirstSync {
      static func differences(local: DeviceSnapshot, remote: DeviceSnapshot) -> [SettingDifference]   // settings keys + goal days on both sides with different content
      static func choose(useThisMac: Bool, local: DeviceSnapshot, remote: DeviceSnapshot, now: Date) -> DeviceSnapshot   // local with every differing setting/goal set to the chosen side, stamped now by local.deviceID
  }
  @MainActor @Observable final class SyncController {
      enum Status: Equatable { case off, syncing, synced(Date), needsFolder, awaitingChoice([SettingDifference]), failed(String) }
      private(set) var status: Status
      private(set) var folderDisplayPath: String?     // e.g. "iCloud Drive › TuneNook"
      private(set) var devices: [RemoteDevice]
      private(set) var notes: [String]
      var isEnabled: Bool { get }
      init(context: ModelContext, defaults: UserDefaults, goalStore: GoalStore, rewards: RewardStore, engine: TimerEngine,
           radio: RadioPlayer?, notifications: NotificationService?, baselineURL: URL, now: @escaping () -> Date = Date.init)
      func start()                                     // launch: resolve bookmark, schedule, run a pass
      func enable(folder: URL) async                   // first sync; may end in .awaitingChoice
      func resolveFirstSync(useThisMac: Bool) async
      func cancelFirstSync()                           // clears bookmark, status .off, nothing written
      func disable()                                   // stop passes; keep local data, baseline and device file
      func syncNow() async
      func removeDevice(_ id: String) throws
  }
  ```
  Device ID: `UUID().uuidString` stored once under defaults key `"sync.deviceID"`. Enabled flag: `"sync.enabled"`. Baseline: JSON at `baselineURL` (app: `Application Support/TuneNook/sync-baseline.json`). Labels for differences: Focus length / Short break / Long break / Long break every / Start breaks automatically / Start focus automatically / Pause when the Mac locks / Pause when idle / Music on breaks / Break station / Radio station / Celebrations / New day starts at / Menu bar icon / "Daily goal from <date>".

A pass (`syncNow`): read folder (off main) → on main: `capture(baseline)` → `SyncMerge.merge([local] + read.snapshots, into: local, now)` → `apply(resolve(merged))` while `isApplying = true` → save merged as baseline → write merged as this Mac's file → `status = .synced(now)`, `devices`, `notes` updated. Passes are serialized; a request during a pass runs one more pass after it. `SyncFolderError.needsFolder` → `.needsFolder`; other errors → `.failed(message)`, local data untouched.

`enable(folder:)`: save bookmark, set enabled. If baseline file is absent and `read.snapshots` is non-empty: `local = capture(nil)`, `remote = merge(read.snapshots)`; if `differences` non-empty → keep `local` in memory, `status = .awaitingChoice(diffs)`, return without writing. `resolveFirstSync` → `choose(...)` then a normal pass using that as the local snapshot. Otherwise a normal pass.

Scheduling (`start` and after `enable`): pass at launch; `ModelContext.didSave` (from the main context) and `UserDefaults.didChangeNotification` → debounced pass after 3 s, ignored while `isApplying`; a 120 s repeating timer; `NSWorkspace.didWakeNotification` and `NSApplication.didBecomeActiveNotification` → pass. Nothing runs while disabled or awaiting a choice.

- [ ] **Step 1: Write the failing tests:**
  - `FirstSyncTests.noDifferencesWhenEqual`, `differencesListSettingsAndSameDayGoals` (labels and values as above, goal entries only on one side are not listed), `chooseThisMacStampsLocalValues`, `chooseOtherMacTakesRemoteValues`.
  - `SyncControllerTests` uses two controllers ("Mac A", "Mac B"), each with its own in-memory container, defaults, `GoalStore`, `RewardStore`, `TimerEngine`, baseline file, sharing one temp folder; `radio` and `notifications` nil; `now` injected:
    - `firstMacSyncsWithoutDialog`: A enables on empty folder → `.synced`, `devices/<A>.json` exists.
    - `twoMacsConverge`: A has topic "Work" + 2 sessions, B has "Home" + 1 session; enable A, then B → B awaits choice only if settings differ (set equal here) → after B's pass and another A pass, both stores have both topics and 3 sessions.
    - `secondPassChangesNothing`: after convergence, `syncNow` on A twice → device file bytes identical. **(Review Focus 2)**
    - `editPropagates`, `deletePropagatesAndStaysDeleted` (B re-syncs with an old baseline copy and the topic doesn't come back).
    - `differingSettingsAwaitChoice`: A focus 50, B focus 25; B enables → `.awaitingChoice` with one difference; nothing written to the folder for B; `resolveFirstSync(useThisMac: false)` → B's focus becomes 50; `cancelFirstSync` path → status `.off`, no B file.
    - `unreadableFolderKeepsLocalData`: delete the folder after A syncs → `.failed` or `.needsFolder`, store unchanged.
- [ ] **Step 2: Run** `FirstSyncTests` and `SyncControllerTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `FirstSync`, `SyncController`, and wire it in `TuneNookApp.init` (after the store opens and backfill runs; `radio` and `notifications` are the app's instances; `.environment(syncController)` on `SettingsView`; `start()` at launch).
- [ ] **Step 4: Run** both suites, then the full suite. Expected: PASS.
- [ ] **Step 5: Commit** `feat(sync): sync controller with first-sync choice`.

### Task 9: Merge topic

**Files:**
- Create: `TuneNook/Sync/TopicMerger.swift`, `TuneNook/Views/Main/MergeTopicSheet.swift`
- Modify: `TuneNook/Views/Main/TopicSidebar.swift` (context menu item "Merge into…"), `TuneNook/Sync/SyncController.swift` (pass `TopicMerger.pending(in:)` to `SnapshotCapture.mergedTopics`, and `TopicMerger.clear(_:in:)` for ids whose tombstone is older than 90 days)
- Test: `TuneNookTests/TopicMergerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor enum TopicMerger {
      static func merge(_ source: Topic, into target: Topic, context: ModelContext, defaults: UserDefaults) throws
      static func pending(in defaults: UserDefaults) -> [UUID: UUID]     // defaults key "sync.mergedTopics"
      static func clear(_ sourceIDs: [UUID], in defaults: UserDefaults)
  }
  ```
  `merge` moves every task of `source` to `target`, deletes `source`, saves, records `source.syncID → target.syncID`. It never touches `TimerEngine`. Throws if `source === target`.

Sheet: title "Merge “<source>” into…", a list of the other topics (color dot + name), footer "Moves <N> tasks and their history into the topic you pick, then deletes “<source>”.", buttons Cancel / Merge (disabled until a topic is picked). After merging, if the sidebar selection was the source, select the target. The menu item is hidden when there is only one topic.

- [ ] **Step 1: Write the failing tests:**
  - `movesTasksAndSessions`: source with 2 tasks (one with 3 sessions) → target has 2 more tasks, sessions still linked, source gone.
  - `recordsMergeForSync`: `pending` returns `[source.syncID: target.syncID]`; `clear` removes it.
  - `runningTaskKeepsRunning`: engine running on a task in source → after merge, `engine.isActive`, `engine.currentTask` is the same task, its `topic` is target.
  - `mergeIntoSelfThrows`.
  - `syncedMergeRedirectsLateTask` (in `SyncControllerTests`): A merges X into Y and syncs; B (not yet synced since) adds a task to X, then syncs; after A syncs, both Macs have the task in Y and no X.
- [ ] **Step 2: Run** `TopicMergerTests` and `SyncControllerTests/syncedMergeRedirectsLateTask`. Expected: FAIL.
- [ ] **Step 3: Implement** `TopicMerger`, the sheet and the menu item; wire `pending`/`clear` into the controller.
- [ ] **Step 4: Run** both. Expected: PASS.
- [ ] **Step 5: Commit** `feat: merge one topic into another`.

### Task 10: Sync settings tab and docs

**Files:**
- Create: `TuneNook/Views/Settings/SyncSettingsTab.swift`
- Modify: `TuneNook/Views/Settings/SettingsView.swift` (tab after Rewards: `Label("Sync", systemImage: "arrow.triangle.2.circlepath.icloud")`), `README.md`
- Test: `TuneNookTests/SyncSettingsTests.swift`

**Interfaces:**
- Consumes: `SyncController` (Task 8).
- Produces: `struct SyncStatusText { static func describe(_ status: SyncController.Status, now: Date) -> String }` for testable copy.

Layout and copy as in the spec's "Settings → Sync tab" sketch:
- Toggle "Sync between Macs". Turning on opens `NSOpenPanel` (`canChooseDirectories = true`, `canChooseFiles = false`, `canCreateDirectories = true`, `directoryURL` = `~/Library/Mobile Documents/com~apple~CloudDocs` if it exists, prompt "Use Folder", message "Choose a folder in iCloud Drive, e.g. a new folder named TuneNook. Pick the same folder on your other Mac.") then `enable(folder:)`. Panel cancelled → toggle stays off.
- Folder row with **Change…** (same panel, then `enable`).
- Status line: off → "Off"; syncing → "Syncing…"; synced → "Synced just now" / "Synced N minutes ago" (via `RelativeDateTimeFormatter`); needsFolder → "Can't open the sync folder. Choose it again." with a **Choose…** button; failed → the message.
- "Macs in this folder": this Mac "(this Mac)", others "last synced <relative>"; stale ones "inactive" + **Remove** (confirm "Remove <name> from sync? Its file is deleted from the folder. Data on this Mac stays.").
- Notes from `controller.notes` in footnote red.
- Footer: "In Finder, right-click the folder and choose Keep Downloaded (on macOS 14, turn off Optimize Mac Storage). Don't also sync this folder with Dropbox or OneDrive."
- **Sync Now** button.
- First-sync dialog when `status` is `.awaitingChoice(diffs)`: alert title "Your settings differ from <other device name>", message lists each difference as "<label>: <here> here, <there> on <name>", buttons "Use This Mac's", "Use <name>'s", "Cancel" (→ `cancelFirstSync`). With several other devices, `<name>` is "the other Macs".

README: a "Sync between Macs" feature bullet (v0.9) and a short "Set up sync" section (turn on in Settings → Sync on the first Mac, pick a folder in iCloud Drive, turn on on the second Mac and pick the same folder; Keep Downloaded tip; what syncs and what doesn't). Roadmap: add `| **v0.9** | Sync between Macs via iCloud Drive |`; remove "iCloud sync" from Later.

- [ ] **Step 1: Write the failing tests** for `SyncStatusText.describe`: each status → its copy; `synced` 30 s ago → "Synced just now", 5 min ago → "Synced 5 minutes ago".
- [ ] **Step 2: Run** `SyncSettingsTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the tab, the dialog, `SyncStatusText`, README changes.
- [ ] **Step 4: Run** the full suite. Expected: PASS. Build and run the app (`open build/Build/Products/Debug/TuneNook.app`), turn sync on with a temp folder in iCloud Drive, confirm `devices/<id>.json` appears and the status reads "Synced just now".
- [ ] **Step 5: Commit** `feat(sync): Sync settings tab`.
