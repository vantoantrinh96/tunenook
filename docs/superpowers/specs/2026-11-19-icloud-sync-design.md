# Sync between Macs (iCloud Drive folder)

## Intent

The owner works on two Macs, a work Mac and a personal Mac, both signed in to the same Apple ID. They want everything TuneNook records and every setting that isn't tied to one machine to be the same on both, so topics, tasks, focus history, streaks, goals and rewards are one shared record rather than two halves.

The owner has no paid Apple Developer account, so CloudKit and an app-owned iCloud container are not available. Sync goes through an ordinary folder in iCloud Drive that the user picks, the same way Obsidian keeps a vault in iCloud Drive and lets iCloud move the files.

## Goals

- Topics, tasks and focus sessions created, edited or deleted on one Mac show up on the other within a few minutes of both being online and running TuneNook.
- Streak, heatmap, progress page and estimate stats on each Mac are computed from the combined history of both.
- Synced settings: timer durations and auto-start, away policy, music rules and break station, selected radio station, celebration level, daily goal history and day start hour, unlocked menu bar icons and the selected icon.
- No data is ever lost by turning sync on, including when both Macs already have data.
- A **Merge topic** action lets the user fold one topic into another, so duplicates created before sync (two "Work" topics) can be cleaned up by hand.
- Sync is off until the user turns it on in Settings and picks a folder.

## Non-goals

- A timer that is running or paused. It stays on its own Mac; the session joins the shared history when it ends.
- Machine-tied settings: MCP server on/off, port and token, global shortcut, open at login, update preferences, the estimate-range picker and other view state.
- Automatic matching of records by name. Duplicates are merged by the user.
- Merging duplicate tasks (only topics have a merge action in this round).
- CloudKit, a TuneNook server, LAN or peer-to-peer sync, Windows, iOS.
- Sync while TuneNook isn't running.
- Real-time (seconds) latency.

## Anti-goals

- Opening the SwiftData/SQLite store from iCloud Drive or from two Macs. Each Mac keeps its own store where it is today.
- Two Macs writing the same file in the sync folder (iCloud would create conflict copies like `name 2.json`).
- A deleted record coming back because the other Mac had an old copy.
- A focus session being lost, counted twice, or attached to the wrong task.
- Sync disturbing a running focus session (e.g. a remote delete of the task being timed must not crash or silently end it without the user seeing why).
- Rewriting whether past days met their goal (`GoalHistory` rule still holds).
- A sync folder that can't be read turning into wiping local data.

## Constraints (from the project)

- macOS 14+, Apple silicon, Swift 6, XcodeGen (`project.yml` is the source of truth for entitlements and settings).
- App Sandbox on, Hardened Runtime on, ad-hoc signing, `DEVELOPMENT_TEAM: ""`. No iCloud entitlement is possible. The sandbox can only reach a user-chosen folder through `NSOpenPanel` plus a security-scoped bookmark, which needs `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`. Both work with ad-hoc signing.
- Ad-hoc signatures change every build. Check whether an app-scoped bookmark still resolves after a Sparkle update; if it goes stale, the app must notice and ask the user to pick the folder again rather than fail silently.
- Data today: SwiftData models `Topic`, `TodoTask`, `FocusSession` in one `ModelContainer`, used from `mainContext`. They have no ID field of their own and no modified date.
- Writers of that data: views (`TopicSidebar`, `TopicEditor`, `TaskListView`, …), `SessionCoordinator` (inserts `FocusSession` on phase end) and the MCP tools (`TopicTools`, `TaskTools`). Sync must catch changes from all of them without each one having to remember to.
- Settings live in `UserDefaults.standard`, read through `TimerSettings.load`, `AwayPolicy.load`, `MusicRules.load`, `CelebrationLevel`, `RadioPlayer` and bound in the Settings UI with `@AppStorage`. `GoalStore` and `RewardStore` hold state in memory and write through to defaults, so applying a remote change to them must go through the store, not straight to defaults.
- `TimerEngine.currentTask` holds a `TodoTask`; deleting it from the UI calls `engine.abandon()` (`TaskListView.delete`, `TopicSidebar.delete`).
- iCloud Drive may evict files ("Optimize Mac Storage"); an evicted file is a placeholder that must be downloaded before it can be read.
- The MCP server shipped in v0.8.0 (PR #17); branch from current `main`.

## Approaches considered

1. **One snapshot file per Mac in a shared iCloud Drive folder** (chosen by the owner). Each Mac writes only `devices/<deviceID>.json`, holding its full current state with UUIDs, modified dates and tombstones. Each Mac reads every other device file and merges record by record. No two Macs ever write the same file, so iCloud never makes conflict copies. Rewrites the whole file on every export, which is fine at TuneNook's size (thousands of sessions is a few hundred KB).
2. **Per-device change log.** Each Mac appends its changes; the others replay them. Smaller writes and a history of changes, but needs read cursors per device and log compaction. Too much machinery for this data size.
3. **One file per record, named by UUID** (Obsidian-style, raised by the owner). Natural for notes, but two Macs editing the same topic write the same file and iCloud makes duplicates; thousands of session files sync slowly; deleting a file can be undone by an offline Mac re-writing it.
4. **CloudKit / `ModelConfiguration(cloudKitDatabase:)`.** The cleanest for SwiftData, but needs a paid developer account and iCloud entitlement. Out of reach.
5. **Putting the SwiftData store in iCloud Drive.** Corrupts SQLite. Rejected.

Also settled with the owner: records get UUIDs, nothing is matched by name, and a manual **Merge topic** action handles duplicates. Merging keeps the target topic's UUID and tombstones the source (the owner's draft suggested a new UUID for the merged topic; keeping the target's ID was proposed so an offline Mac's references never point at a vanished ID, and the owner agreed).

## Design

### Folder layout

```
<sync folder>/            e.g. iCloud Drive/TuneNook
  devices/
    <deviceID>.json       one per Mac, written only by that Mac
```

- `deviceID`: a UUID generated once per Mac and kept in local defaults (not synced). The file also holds a human-readable device name (`Host.current().localizedName`) for the Settings list.
- Writes are atomic (write to a temp file in the same folder, then replace) and go through `NSFileCoordinator`.
- Unknown files in the folder are ignored. Files whose `formatVersion` is newer than the app understands are ignored, and Settings says "Update TuneNook on this Mac to sync with <device>".

### Device file contents

```json
{
  "formatVersion": 1,
  "deviceID": "…", "deviceName": "Work MacBook", "appVersion": "0.9.0",
  "exportedAt": "2026-11-19T10:00:00Z",
  "topics":   [{ "id": "…", "modifiedAt": "…", "deleted": false, "name": "…", "colorHex": "…", "createdAt": "…", "deadline": null }],
  "tasks":    [{ "id": "…", "modifiedAt": "…", "deleted": false, "title": "…", "estimatedSessions": 2, "isDone": false, "createdAt": "…", "completedAt": null, "topicID": "…" }],
  "sessions": [{ "id": "…", "modifiedAt": "…", "deleted": false, "kind": "focus", "startedAt": "…", "endedAt": "…", "activeSeconds": 1500, "completed": true, "taskID": "…" }],
  "settings": { "timer.focusMinutes": { "value": 50, "modifiedAt": "…" }, "…": {} },
  "goals": [{ "day": "2026-11-12", "kind": "minutes", "target": 120, "modifiedAt": "…", "deleted": false }],
  "unlockedIcons": ["note", "timer"]
}
```

A device file holds every record that Mac knows, including ones it received from other Macs, plus tombstones (`deleted: true`, other fields may be dropped). A topic tombstone created by **Merge topic** also carries `"mergedInto": "<target topic id>"`. Tombstones are kept for 90 days, then pruned.

**Stale device files** (my call, from the builder check): a device file whose `exportedAt` is older than the tombstone window (90 days) is ignored on import, so a retired Mac's old file can't bring pruned records back. Settings lists it as "inactive" with a **Remove** button that deletes that file. Turning sync off leaves this Mac's file in place; once it is older than 90 days it is ignored like any stale file. Turning sync back on after that does a fresh first sync (below) from the local store.

### Model changes

- Add to `Topic`, `TodoTask`, `FocusSession`: `syncID: UUID` (default `UUID()`) and `modifiedAt: Date` (default `.distantPast` for migrated rows, so any remote edit wins over untouched old data). Lightweight migration fills existing rows; every existing row gets a fresh UUID on first launch.
- Tombstones for deleted records live in a small local table (e.g. a `SyncTombstone` model: kind, syncID, deletedAt) since the record itself is gone.

### Catching local changes

Rather than editing every writer, a `SyncEngine` keeps the last exported state as a baseline and diffs the current store against it on each export: a record that differs from the baseline gets `modifiedAt = now`; a record in the baseline but missing from the store gets a tombstone. This catches edits from views, `SessionCoordinator` and MCP tools alike. The builder may instead stamp `modifiedAt` at the writers or on `ModelContext.didSave`, as long as every writer is covered and tests prove it.

### Merge rule

For each record ID across the local store and all device files:

- Newest `modifiedAt` wins, tombstones included (a delete newer than an edit deletes; an edit newer than a delete re-creates). Ties break on the higher `deviceID` string so every Mac picks the same winner.
- Focus sessions are effectively append-only; the same rule still applies.
- **Tasks and their topic** (my calls, from the builder check):
  - A task's `topicID` is resolved through `mergedInto` chains first. A task that points at a merged-away topic lands in the target, whether it was created before or after the merge and whichever Mac wins the task's own last-write-wins. Merging therefore never loses a task, even one added on an offline Mac.
  - A task whose topic was **deleted** (not merged) is deleted with it, as today's cascade does, even if the task was edited after the delete on another Mac. Its focus sessions are kept with no task (today's `.nullify`), so no focus time is lost.
  - Deletions caused by applying a remote tombstone (the cascade on import) are **not** local edits: they create no new tombstones with a fresh `modifiedAt` and are not echoed back. The baseline is updated to the merged result, so the next export's diff doesn't see them as changes.
  - A task whose topic isn't known yet (not in any file read so far) is held back: kept in the merge state, not inserted into the store, until its topic appears. Since every device file holds a full snapshot, this only happens with a half-synced file and resolves on the next pass. Tasks never show without a topic, matching the UI and `TaskTools` ("a task must belong to a topic").
- A session whose `taskID` is gone keeps the session with no task (matches today's `.nullify`).
- Settings: per key, newest `modifiedAt` wins. `dayStartHour` is a normal setting.
- **Goal history** (my call, from the builder check): merged per entry, keyed by the entry's focus day (`effectiveFrom`). Each entry has its own `modifiedAt` and can be tombstoned. Entries from both Macs are unioned; the same day on both sides is decided by newest `modifiedAt`. `GoalStore.setGoal` today removes entries on or after the day it sets; those removals become entry tombstones. Result: a goal set on one Mac on day 10 and another set offline on day 12 both survive, and past days keep the goal they were judged by. Pre-sync entries get `modifiedAt = .distantPast`; at first sync both histories are unioned, and on a same-day clash the rule for first-sync settings below decides.
- Unlocked icons: union. The selected icon is a normal setting, applied only if unlocked locally after the union.
- Rewards and streaks are not synced as numbers; they are recomputed from the merged history as today.

Applying a merge writes into the local SwiftData store and through `GoalStore` / `RewardStore` / `RadioPlayer` / defaults so open windows update live. Writing the merge result must not itself look like a local edit (no `modifiedAt` bump).

### Running session

If a merge deletes the task (or its topic) that `TimerEngine.currentTask` points at while a session is running or paused, the session keeps running with no task, and the user gets a notification ("<task> was deleted on <device>"). The finished session is saved with no task. Do not call `abandon()` from sync.

### When sync runs

- Import + export at launch (after the store opens) and when sync is turned on.
- Export a few seconds after any local change (debounced), including after a session is saved.
- Import when a device file changes: `NSFilePresenter` / `NSMetadataQuery` on the folder if it works for a user-chosen folder under the sandbox; otherwise poll every 2 minutes and on wake / app activation. Builder's call, with polling as the fallback.
- If a device file is evicted, call `FileManager.startDownloadingUbiquitousItem(at:)` and pick it up on the next pass.

### Settings → Sync tab

```
Sync between Macs                         [ On ]
Folder:  iCloud Drive › TuneNook          [Change…]
Status:  Synced 2 minutes ago
Macs in this folder:
  • Work MacBook (this Mac)   synced 2 min ago
  • Personal MacBook          last seen 3 hours ago
ⓘ In Finder, right-click the folder and choose Keep Downloaded
   (macOS 14: turn off Optimize Mac Storage). Don't also sync this
   folder with Dropbox or OneDrive.
[Sync Now]
```

- Turning it on opens `NSOpenPanel` (directories only, starts in iCloud Drive, offers "New Folder"), defaulting to a `TuneNook` folder there.
- Errors shown in Status: folder unavailable / bookmark stale ("Choose the folder again"), iCloud not signed in, a device file from a newer version, a file that couldn't be parsed (that device is skipped; local data untouched).
- Turning sync off stops reading and writing; local data stays. The device file is left in place.

### First sync with existing data on both Macs

Records: nothing special. Each Mac's existing rows already have UUIDs, so the union shows everything from both. Duplicate topics appear side by side and the user merges them.

Settings and goals (decided by the owner: **ask**). Pre-sync settings and goal entries have no timestamps (`modifiedAt = .distantPast`). When sync is turned on and the folder already has at least one active device file:

- Compare this Mac's synced settings and goal entries with the merged values from the folder. If they are all equal, continue silently.
- If any differ, show a dialog before importing: "Your settings differ from <device name>. Use this Mac's settings or <device name>'s?" listing the differing items in plain words (e.g. "Focus length: 50 min here, 25 min on Personal MacBook"; "Daily goal from Nov 12: 120 min here, 4 sessions there"). Two buttons: **Use This Mac's** / **Use <device>'s**. With more than one other device, the choice is "this Mac" vs "the folder" and names come from the newest device file.
- The chosen side's values for the differing keys and goal days are stamped `modifiedAt = now`, so they win everywhere; the other side's values are overwritten. Goal entries that exist on only one side are unioned, not asked about.
- Cancelling the dialog cancels turning sync on (nothing is written to the folder).
- The first Mac to turn sync on (empty folder) never sees the dialog.

### Merge topic

- In the topic sidebar context menu: **Merge into…** → pick another topic → confirm ("Move N tasks from A into B and delete A?").
- Moves all tasks of A into B (their `modifiedAt` bumps), then deletes A (tombstone). B keeps its ID, name, color and deadline.
- Allowed whether or not sync is on. If A's task is the running task, the session continues on the same task, now under B.
- Not exposed as an MCP tool in this round (builder may add it if trivial).

### MCP

No new tools. Records changed by MCP tools sync like any other change. MCP's entity IDs (`EntityID.swift`) are unaffected unless the builder chooses to switch them to `syncID`, which would be a separate change.

## Testing

- Unit tests for the merge rule: edit vs edit, edit vs delete both orders, tie-break, task with missing topic, session with missing task, settings per key, goal history, icon union, tombstone pruning.
- Round trip: two in-memory stores, two temp folders standing in for two Macs sharing one folder; changes on each converge to the same state.
- Change detection covers views' writes, `SessionCoordinator` inserts and MCP tool writes.
- Migration: an existing store without `syncID`/`modifiedAt` opens, gets IDs, and nothing is lost.
- Running-session case: remote delete of the current task keeps the timer running.
- Merge topic: tasks and their sessions move, source tombstoned, running task unaffected.
- Corrupt / newer-format device file is skipped without touching local data.
- Merge topic on one Mac while the other, offline, adds a task to the source topic: the task ends up in the target.
- Remote cascade doesn't echo new tombstones back.
- Stale device file (older than 90 days) is ignored and can be removed.
- Goal entries set on different days on two Macs both survive; same-day clash follows `modifiedAt`.
- First-sync settings dialog: no dialog when equal or when the folder is empty; each button applies the chosen side; cancel writes nothing.

## Left to the builder

- Exact Swift types and file split (suggested: `TuneNook/Sync/` with `SyncEngine`, `DeviceSnapshot` (Codable), `SyncMerge` (pure, unit-tested), `SyncFolder` (bookmark + file coordination), `SyncSettingsView`).
- Folder watching vs polling, debounce and poll intervals, tombstone window.
- Whether change detection is baseline-diff or stamping at the writers.
- How the baseline is stored (e.g. the last exported device file itself).
- README: a Sync section and the roadmap row ("iCloud sync" moves from Later to a version).
