# MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TuneNook runs a local, token-protected MCP server so AI agents can manage topics, tasks and settings and read focus history.

**Architecture:** An SDK-free tool layer (`TuneNookTools`) takes a tool name and JSON arguments and returns JSON, working on the app's own `ModelContext`, `UserDefaults` and `GoalStore` on the main actor. A thin adapter registers those tools on an MCP `Server` from the official Swift SDK. A small `Network.framework` listener on IPv4 loopback parses HTTP, runs a request gate (path, Host, Origin, bearer token) and hands requests to the SDK's `StatelessHTTPServerTransport`. `MCPServerController` owns on/off, port, token and status, and a new Settings tab drives it.

**Tech Stack:** Swift 6, SwiftUI, SwiftData, Network.framework, `modelcontextprotocol/swift-sdk` 0.12.1 (product `MCP`), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-19-mcp-server-design.md`

## Global Constraints

- macOS 14+, Apple silicon, Swift 6. Edit `project.yml`, never the `.xcodeproj`, `Info.plist` or entitlements; run `xcodegen generate` after editing it.
- Xcode 16.3 or newer (the SDK needs swift-tools-version 6.1).
- Work on a new branch `feat/mcp-server` created from `feat/auto-update`.
- All data access on the main actor through `container.mainContext`, with `try context.save()` after every write.
- The listener binds IPv4 loopback only. Never a wildcard address.
- The token never appears in logs, and no real-looking token is committed: tests use the literal `test-token` (Gitleaks and Semgrep run in CI).
- Non-goals stay out: no timer or radio control, no session writes, no shortcut / login / update / icon settings, no resources or prompts, no stdio helper.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`), `@testable import TuneNook`, one suite per file in `TuneNookTests/`.
- Test command (`<Suite>` is the struct name):
  `xcodegen generate && xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build test -only-testing:TuneNookTests/<Suite>`
- Commit messages follow Conventional Commits and end with the `Co-Authored-By` line the session provides.

## Review Focus

1. **A client reconnects.** Claude Code is restarted and sends `initialize` again to the same running server. Expected: the second handshake succeeds and tools work. (Task 4)
2. **The port is already taken.** Expected: status becomes "failed" with a readable reason, the app keeps running, and turning the server off and on again after the port frees up works. (Tasks 5, 6)
3. **Malformed or huge HTTP input** (garbage bytes, no `Content-Length`, a 50 MB body, a client that connects and sends nothing). Expected: 400 or 413 or a closed connection, bounded memory, no crash. (Task 5)
4. **A stale id.** An agent uses the id of a task or topic deleted a moment ago, or an id of the wrong kind (a topic id passed as `task_id`). Expected: a tool error saying it wasn't found. (Task 1)
5. **Loose date input.** An agent sends `"2026-12-01"` for a deadline or a `from` date, with no time or zone. Expected: accepted as that day in the user's time zone; anything unparseable is a tool error naming the field. (Tasks 1, 3)

---

## File structure

| File | Responsibility |
|---|---|
| `TuneNook/MCP/Tools/TuneNookTools.swift` | Entry point `call(_:arguments:)`, `ToolError`, JSON coding, shared helpers (date parsing, id resolving) |
| `TuneNook/MCP/Tools/EntityID.swift` | `PersistentIdentifier` ⇄ opaque string |
| `TuneNook/MCP/Tools/TopicTools.swift` | `list_topics`, `create_topic`, `update_topic`, `delete_topic` |
| `TuneNook/MCP/Tools/TaskTools.swift` | `list_tasks`, `create_task`, `update_task`, `delete_task` |
| `TuneNook/MCP/Tools/SettingsTools.swift` | `get_settings`, `update_settings` |
| `TuneNook/MCP/Tools/HistoryTools.swift` | `list_sessions`, `get_progress` |
| `TuneNook/MCP/MCPToolCatalog.swift` | The 12 `Tool` definitions (name, description, JSON Schema, annotations) |
| `TuneNook/MCP/MCPServerFactory.swift` | Builds an SDK `Server` wired to `TuneNookTools` |
| `TuneNook/MCP/HTTP/HTTPMessage.swift` | Parse raw bytes into `HTTPRequest`; serialize `HTTPResponse` |
| `TuneNook/MCP/HTTP/RequestGate.swift` | Path, Host, Origin and bearer checks |
| `TuneNook/MCP/HTTP/LoopbackHTTPServer.swift` | `NWListener` on 127.0.0.1 |
| `TuneNook/MCP/MCPServerController.swift` | Enabled, port, token, status, start/stop |
| `TuneNook/MCP/MCPConnectionSnippets.swift` | Copyable client command and JSON |
| `TuneNook/Views/Settings/AgentsSettingsTab.swift` | The Agents tab |
| Modify `TuneNook/Views/Settings/SettingsView.swift`, `TuneNook/App/TuneNookApp.swift`, `project.yml`, `README.md` | Wiring, dependency, entitlement, docs |

---

### Task 1: Tool layer core, topics and tasks

**Files:**
- Create: `TuneNook/MCP/Tools/TuneNookTools.swift`, `EntityID.swift`, `TopicTools.swift`, `TaskTools.swift`
- Test: `TuneNookTests/TopicTaskToolsTests.swift`

**Interfaces:**
- Produces:

```swift
struct ToolError: Error, Equatable { let message: String }

@MainActor
final class TuneNookTools {
    init(context: ModelContext,
         defaults: UserDefaults,
         goalStore: GoalStore,
         stations: [RadioStation],
         isBusy: @escaping (TodoTask) -> Bool,      // a focus session is active on this task
         deselect: @escaping (TodoTask) -> Void,    // clear engine.currentTask if it is this task
         now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current)
    /// Runs one tool. `arguments` is a JSON object (empty data means `{}`). Returns a JSON object.
    /// Throws `ToolError` for anything the agent got wrong; nothing else escapes.
    func call(_ name: String, arguments: Data) throws -> Data
    static let toolNames: [String]   // all 12, in catalog order
}

enum EntityID {
    static func encode(_ id: PersistentIdentifier) -> String   // base64url of its JSON encoding
    static func decode(_ string: String) -> PersistentIdentifier?
}
```

- JSON rules for every tool, fixed here: keys are snake_case (`.convertToSnakeCase` / `.convertFromSnakeCase`); output dates are ISO 8601 with time zone; input dates accept full ISO 8601 or `YYYY-MM-DD` (start of that day in `calendar`); unknown argument keys are ignored; a wrong JSON type is a `ToolError` naming the field.
- Resolve ids by **fetching** with `#Predicate { $0.persistentModelID == id }`, never `context.model(for:)`, which hands back a fault for a row that no longer exists. A missing, malformed or wrong-kind id throws `ToolError("No task with that id.")` / `"No topic with that id."`.
- Results:
  - Topic: `{id, name, color, deadline, open_tasks, done_tasks}`
  - Task: `{id, title, topic_id, topic_name, estimated_sessions, actual_sessions, done, created_at, completed_at}`
  - `list_*` wrap in `{topics: [...]}` / `{tasks: [...]}`; create and update return the single object; deletes return `{deleted: true}`.
- Rules from the spec: names and titles are trimmed and must not be empty; `color` must be in `Topic.palette` (default `Topic.palette[0]`); `estimated_sessions` is `1...12` (default 1); `create_task` requires `topic_id`; `update_task.topic_id` moves and cannot be null; `update_topic.deadline` distinguishes absent (keep) from `null` (clear) with a custom `init(from:)` using `container.contains`; `done` goes through `TodoTask.setDone(_:at:)` with `now()`; `list_tasks.status` is `open` (default), `done` or `all`, ordered like `Topic.openTasks` / `doneTasks`; `list_topics` is ordered by `createdAt`.
- Deletes: if `isBusy` is true for the task (or any task of the topic), throw `ToolError("A focus session is running on this task. Stop it in TuneNook first.")` and change nothing. Otherwise call `deselect` on the task (or every task of the topic), then delete and save.

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feat/mcp-server feat/auto-update
```

- [ ] **Step 2: Write the failing tests** in `TuneNookTests/TopicTaskToolsTests.swift`

A `@MainActor struct TopicTaskToolsTests` with a helper that builds `TuneNookTools` on `ModelContainer(for: Topic.self, TodoTask.self, FocusSession.self, configurations: .init(isStoredInMemoryOnly: true))`, a `UserDefaults(suiteName: UUID().uuidString)`, a `busy: Set<PersistentIdentifier>` box and a `deselected` recorder, plus `call(_ name: String, _ json: String) throws -> [String: Any]`. Tests:

- `createThenListTopic`: create `{"name":"  Thesis ","color":"#43AA8B","deadline":"2026-12-01"}` → name `"Thesis"`, color kept, deadline is local midnight of 2026-12-01; `list_topics` returns it with `open_tasks == 0`.
- `topicValidation`: empty name, color `"#000000"`, deadline `"soon"` each throw `ToolError`; the store stays empty.
- `updateTopicDeadlineNullClearsAbsentKeeps`.
- `createTaskNeedsTopic`: no `topic_id` throws; unknown id throws `"No topic with that id."`.
- `taskEstimateRange`: 0 and 13 throw; 12 is accepted; default is 1.
- `updateTaskDoneSetsCompletedAt` and back to `false` clears it; `update_task` with `"topic_id":null` throws.
- `listTasksStatusFilter`: open / done / all.
- `deleteTaskKeepsSessions`: a `FocusSession` on the task survives with `task == nil`.
- `deleteTopicCascadesTasks`.
- `busyTaskCannotBeDeleted`: with the task in `busy`, `delete_task` and `delete_topic` on its topic throw and nothing is deleted; `update_task` still works.
- `selectedIdleTaskIsDeselectedThenDeleted`: `deselected` contains the task before it is gone.
- `staleAndWrongKindIds` (Review Focus 4): the id of a deleted task, a topic id passed to `delete_task`, and `"not-an-id"` each throw a not-found `ToolError`.
- `idsSurviveReopeningTheStore`: create a container on a temp file URL, create a topic through the tool, drop the container, open a second container on the same URL, and `update_topic` with the old id succeeds.
- `unknownToolThrows`.

- [ ] **Step 3: Run to verify they fail**

Run the test command with `TopicTaskToolsTests`. Expected: build fails, `TuneNookTools` not found.

- [ ] **Step 4: Implement** the four files to the interface above. Save before encoding an id (ids are temporary until the first save). If `idsSurviveReopeningTheStore` cannot be made to pass with encoded `PersistentIdentifier`s, stop and report: the spec's fallback is a stored UUID on `Topic` and `TodoTask`, which changes the schema.

- [ ] **Step 5: Run to verify they pass.** Expected: all `TopicTaskToolsTests` pass.

- [ ] **Step 6: Commit**

```bash
git add TuneNook/MCP TuneNookTests/TopicTaskToolsTests.swift
git commit -m "feat(mcp): topic and task tools"
```

---

### Task 2: Settings tools

**Files:**
- Create: `TuneNook/MCP/Tools/SettingsTools.swift`
- Modify: `TuneNook/MCP/Tools/TuneNookTools.swift` (dispatch two more names)
- Test: `TuneNookTests/SettingsToolsTests.swift`

**Interfaces:**
- Consumes: `TuneNookTools` from Task 1 (`defaults`, `goalStore`, `stations`).
- Produces: tools `get_settings` and `update_settings`.

`get_settings` returns:

```json
{
  "focus_minutes": 25, "short_break_minutes": 5, "long_break_minutes": 15,
  "long_break_interval": 4, "auto_start_breaks": true, "auto_start_focus": false,
  "daily_goal": {"kind": "minutes", "target": 120},
  "day_start_hour": 0,
  "break_music": "lowerVolume", "break_station_id": null,
  "celebrations": "milestones",
  "pause_on_lock": true, "idle_pause_minutes": 0,
  "allowed": {
    "daily_goal_kind": ["minutes", "sessions"],
    "break_music": ["keepPlaying", "lowerVolume", "stop", "switchStation"],
    "celebrations": ["off", "milestones", "everySession"],
    "idle_pause_minutes": [0, 2, 5, 10, 15],
    "stations": [{"id": "...", "name": "..."}]
  }
}
```

`update_settings` takes any subset of the writable fields and returns the same object as `get_settings`. Limits, copied from the Settings UI:

| Field | Allowed | Written to |
|---|---|---|
| `focus_minutes` | 5...90 | `TimerSettings.Key.focusMinutes` |
| `short_break_minutes` | 1...30 | `.shortBreakMinutes` |
| `long_break_minutes` | 5...60 | `.longBreakMinutes` |
| `long_break_interval` | 2...8 | `.longBreakInterval` |
| `auto_start_breaks`, `auto_start_focus` | bool | `.autoStartBreaks`, `.autoStartFocus` |
| `daily_goal` | minutes: 15...600 and a multiple of 15; sessions: 1...16 | `goalStore.setGoal(_:now:)` with `now()` |
| `break_music` | a `MusicRules.BreakAction` raw value | `MusicRules.Key.breakAction` |
| `break_station_id` | an id in `stations`, or `null` to clear | `MusicRules.Key.breakStationID` |
| `celebrations` | a `CelebrationLevel` raw value | `CelebrationLevel.key` |
| `pause_on_lock` | bool | `AwayPolicy.Key.pauseOnLock` |
| `idle_pause_minutes` | in `AwayPolicy.idleChoices` | `AwayPolicy.Key.idleMinutes` |

`day_start_hour` in the arguments throws `ToolError("day_start_hour can only be changed in TuneNook's Settings.")`. Validate every field first, then write: one bad field means nothing is written. An empty argument object throws `ToolError("Nothing to change.")`.

- [ ] **Step 1: Write the failing tests** in `SettingsToolsTests.swift` (`@MainActor struct SettingsToolsTests`, same helper style as Task 1, with two fake `RadioStation`s):

- `defaultsAreReported`: fresh suite → the values in the JSON above, `allowed.stations` has both fakes.
- `updateWritesTheSameKeysTheUIReads`: set `focus_minutes` 50 and `celebrations` `"off"` → `TimerSettings.load(from: defaults).focusMinutes == 50`, `defaults.string(forKey: CelebrationLevel.key) == "off"`.
- `rangeLimits`: `focus_minutes` 4 and 91, `long_break_interval` 1, `idle_pause_minutes` 3, `break_music` `"loud"`, `break_station_id` `"nope"` each throw.
- `oneBadFieldChangesNothing`: `{"focus_minutes":50,"short_break_minutes":99}` throws and `focusMinutes` is still 25.
- `goalGoesThroughGoalStore`: `{"daily_goal":{"kind":"sessions","target":6}}` → `goalStore.current == DailyGoal(kind: .sessions, target: 6)`; target 17, and minutes target 100 (not a multiple of 15), throw.
- `goalChangeDoesNotRewritePastDays`: set a goal with `now` = day 0, change it with `now` = day 5 → `goalStore.history.goal(on: day 2)` is still the first goal.
- `dayStartHourIsReadOnly`: throws, and `goalStore.dayStartHour` is unchanged.
- `clearBreakStationWithNull`.

- [ ] **Step 2: Run to verify they fail.** Expected: `ToolError("Unknown tool…")` or similar for `get_settings`.
- [ ] **Step 3: Implement** `SettingsTools.swift` and add both names to the dispatch and `toolNames`.
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Commit** `feat(mcp): settings tools`.

---

### Task 3: History tools

**Files:**
- Create: `TuneNook/MCP/Tools/HistoryTools.swift`
- Modify: `TuneNook/MCP/Tools/TuneNookTools.swift`
- Test: `TuneNookTests/HistoryToolsTests.swift`

**Interfaces:**
- Consumes: `TuneNookTools`; `FocusProgress(sessions:goalStore:now:)`, `FocusCalendar`, `FocusSession.completedFocus`.
- Produces: tools `list_sessions` and `get_progress`. Neither writes anything.

`list_sessions` arguments: `from?`, `to?` (default: the 7 days ending at `now()`; a `YYYY-MM-DD` `to` means the end of that day), `topic_id?`, `task_id?`, `kind?` (`focus`, `shortBreak`, `longBreak`), `completed_only?` (default false), `limit?` (default 100, 1...500). Filters on `startedAt`. Returns newest first:

```json
{"sessions": [{"kind": "focus", "started_at": "...", "ended_at": "...", "active_minutes": 25,
               "completed": true, "task_id": "...", "task_title": "...", "topic_id": "...", "topic_name": "..."}],
 "has_more": false}
```

`active_minutes` is `focusedDuration / 60`, rounded to one decimal. Task and topic fields are null when the task was deleted.

`get_progress` arguments: `days?` (default 7, 1...366). Returns:

```json
{"today": {"date": "2026-11-19", "minutes": 50, "sessions": 2,
           "goal": {"kind": "minutes", "target": 120}, "goal_met": false},
 "streak": {"current": 3, "longest": 9, "freezes_available": 1},
 "days": [{"date": "2026-11-13", "minutes": 0, "sessions": 0, "goal_met": false}]}
```

`days` has exactly `days` entries ending today, oldest first, using `goalStore.calendar` for day boundaries and `goals.goal(on:)` for each day's goal. `date` is the focus day as `YYYY-MM-DD`.

- [ ] **Step 1: Write the failing tests** in `HistoryToolsTests.swift`, with a fixed `now` and a fixed-time-zone `Calendar` as `FocusStatsTests` does:

- `defaultRangeIsLastSevenDays`: sessions 2 and 10 days old → only the first is returned.
- `newestFirstWithLimitAndHasMore`: 5 sessions, `limit` 2 → 2 returned, `has_more == true`; `limit` 0 and 501 throw.
- `filtersByTopicTaskKindAndCompleted`.
- `sessionOfDeletedTaskHasNullTask`.
- `dateOnlyRange` (Review Focus 5): `{"from":"2026-11-10","to":"2026-11-10"}` returns a session at 23:30 local that day and not one at 00:30 the next; `{"from":"yesterday"}` throws naming `from`.
- `progressMatchesFocusProgress`: two completed 25-minute focus sessions today, goal 50 minutes → `today.minutes == 50`, `goal_met == true`, `streak.current == 1`; `days` has 7 entries, last one is today.
- `progressRespectsDayStartHour`: with `goalStore.dayStartHour = 4`, a session ending at 02:00 counts toward the previous day.
- `historyToolsDoNotWrite`: `context.hasChanges == false` after both calls.

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** Fetch with a `FetchDescriptor` predicate on `startedAt` and filter the rest in memory; fetch `limit + 1` rows' worth after filtering to compute `has_more`.
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Commit** `feat(mcp): history tools`.

---

### Task 4: MCP adapter

**Files:**
- Modify: `project.yml` (package `MCP`, target dependency)
- Create: `TuneNook/MCP/MCPToolCatalog.swift`, `TuneNook/MCP/MCPServerFactory.swift`
- Test: `TuneNookTests/MCPAdapterTests.swift`

**Interfaces:**
- Consumes: `TuneNookTools.call(_:arguments:)`, `TuneNookTools.toolNames`.
- Produces:

```swift
enum MCPToolCatalog {
    static let tools: [MCP.Tool]            // 12 tools, names equal to TuneNookTools.toolNames
}
enum MCPServerFactory {
    /// A server named "tunenook" with the tools capability and both handlers registered. Not started.
    static func makeServer(tools: TuneNookTools, version: String) async -> MCP.Server
}
```

- `project.yml`: add under `packages:` `MCP: { url: https://github.com/modelcontextprotocol/swift-sdk, exactVersion: 0.12.1 }` and under the app target's `dependencies:` `- package: MCP` (product `MCP`).
- Each `Tool` has a one-sentence description that says what it does and what it returns, a JSON Schema `inputSchema` with `type: object`, `properties` (each with a `description`, enums and min/max copied from Tasks 1–3) and `required`, and annotations: `readOnlyHint: true` for the two `list_*` topic/task tools, `get_settings`, `list_sessions`, `get_progress`; `destructiveHint: true` for `delete_topic` and `delete_task`; `openWorldHint: false` for all.
- `ListTools` returns the catalog. `CallTool` encodes `params.arguments` to JSON data, hops to the main actor to run `tools.call`, and returns the result as one `.text` content. A `ToolError` becomes `isError: true` with its message as text; any other error becomes `isError: true` with `"TuneNook couldn't complete that."`.

- [ ] **Step 1: Add the dependency** to `project.yml`, run `xcodegen generate`, and build:
`xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build build`. Expected: `BUILD SUCCEEDED` with the `MCP` package resolved.

- [ ] **Step 2: Write the failing tests** in `MCPAdapterTests.swift`, connecting an SDK `Client` to the server over `InMemoryTransport`:

- `catalogMatchesToolLayer`: `MCPToolCatalog.tools.map(\.name) == TuneNookTools.toolNames`, and every schema has `type == "object"`.
- `listToolsOverMCP`: the client lists 12 tools.
- `callToolRoundTrip`: `create_topic` with `name: "Thesis"` then `list_topics` → the text content parses as JSON with one topic named `Thesis`, `isError` false.
- `toolErrorBecomesIsError`: `create_task` without `topic_id` → `isError == true` and the text mentions the topic.
- `secondInitializeSucceeds` (Review Focus 1): disconnect the first client, connect a second client to the same `Server` through a fresh handshake, list tools. If the SDK's `Server` refuses a second `initialize` on one transport, the fix belongs here: build a new `Server` + transport pair per handshake inside a small owner type, and Task 5 uses that owner. Record which it was in the commit message.

- [ ] **Step 3: Run to verify they fail.**
- [ ] **Step 4: Implement** the catalog and the factory.
- [ ] **Step 5: Run to verify they pass.**
- [ ] **Step 6: Commit** `feat(mcp): expose tools through the MCP SDK` (include `project.yml`).

---

### Task 5: Loopback HTTP server and request gate

**Files:**
- Modify: `project.yml` (entitlement `com.apple.security.network.server: true`)
- Create: `TuneNook/MCP/HTTP/HTTPMessage.swift`, `RequestGate.swift`, `LoopbackHTTPServer.swift`
- Test: `TuneNookTests/HTTPMessageTests.swift`, `RequestGateTests.swift`, `LoopbackHTTPServerTests.swift`

**Interfaces:**
- Consumes: SDK types `HTTPRequest`, `HTTPResponse`.
- Produces:

```swift
enum HTTPMessage {
    enum Parsed { case incomplete, request(HTTPRequest), failure(status: Int) }
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 1024 * 1024
    static func parse(_ buffer: Data) -> Parsed
    static func serialize(_ response: HTTPResponse) -> Data            // always Connection: close
    static func serialize(status: Int) -> Data                         // empty-body error
}

struct RequestGate: Sendable {
    let token: String
    let port: Int
    /// nil means let it through.
    func rejection(for request: HTTPRequest) -> HTTPResponse?
}

final class LoopbackHTTPServer: Sendable {
    enum StartError: Error, Equatable { case portInUse, failed(String) }
    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse)
    func start() async throws       // returns once listening; throws StartError
    func stop()                     // closes the listener and every open connection
}
```

- `parse`: HTTP/1.1 only. Header block over `maxHeaderBytes` → `failure(431)`; a `POST` without `Content-Length` → `failure(411)`; `Transfer-Encoding: chunked` → `failure(411)`; `Content-Length` over `maxBodyBytes` → `failure(413)`; an unparseable request line → `failure(400)`. `path` drops the query string. Duplicate headers: last one wins.
- `RequestGate`, in this order: path is not `/mcp` → 404; `Host` missing or not `127.0.0.1:<port>` / `localhost:<port>` → 403; `Origin` present and not `http://127.0.0.1:<port>` / `http://localhost:<port>` → 403; `Authorization` not exactly `Bearer <token>` → 401 with `WWW-Authenticate: Bearer`. Compare the token over its UTF-8 bytes in constant time (XOR-accumulate; unequal lengths fail without an early return on content).
- `LoopbackHTTPServer`: `NWListener` with `NWParameters.tcp`, `requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port:)`, `allowLocalEndpointReuse = true`. One request per connection, then close. A connection that sends nothing complete within 10 seconds is closed. Map `NWError.posix(.EADDRINUSE)` to `.portInUse`.

- [ ] **Step 1: Write the failing pure tests**

`HTTPMessageTests`: `parsesPostWithBody`; `incompleteUntilBodyArrives` (feed the same request in two halves); `headerLookupIsCaseInsensitive`; `pathDropsQuery`; `rejectsGarbage` (400), `missingContentLength` (411), `chunked` (411), `hugeDeclaredBody` — `Content-Length: 52428800` → 413 before any body is buffered (Review Focus 3), `oversizedHeaders` (431); `serializeSetsContentLengthAndClose`.

`RequestGateTests` with `RequestGate(token: "test-token", port: 47821)`: `acceptsGoodRequest`; `wrongPath` 404; `missingHost` 403; `foreignHost` (`evil.example:47821`) 403; `wrongPortHost` 403; `foreignOrigin` (`https://evil.example`) 403; `loopbackOriginAllowed`; `missingToken` 401 with the `WWW-Authenticate` header; `wrongToken` 401; `tokenPrefixIsNotEnough` (`Bearer test-toke`) 401; `basicSchemeRejected` 401.

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** `HTTPMessage` and `RequestGate`. Run both suites. Expected: pass.
- [ ] **Step 4: Add the entitlement** to `project.yml` and run `xcodegen generate`.

- [ ] **Step 5: Write the failing listener tests** in `LoopbackHTTPServerTests` (pick a random port in 49152...65000 per test; `URLSession` with an ephemeral configuration):

- `servesARequest`: handler returns `.data` → the client gets 200 and the body.
- `boundToLoopbackOnly`: the listener's local endpoint host is `127.0.0.1`.
- `secondServerOnSamePortFails` (Review Focus 2): throws `StartError.portInUse`; after the first `stop()`, a new server on that port starts.
- `garbageGets400AndCloses`, `silentClientIsDropped` (Review Focus 3): open a raw `NWConnection`, send `"hello\r\n\r\n"` → the reply starts with `HTTP/1.1 400`; open another and send nothing → the server closes it (allow the test a shortened timeout through an internal `idleTimeout` parameter defaulting to 10 seconds).
- `stopClosesTheListener`: a request after `stop()` fails to connect.

- [ ] **Step 6: Run to verify they fail, implement `LoopbackHTTPServer`, run to verify they pass.**
- [ ] **Step 7: Commit** `feat(mcp): loopback HTTP server with request gate` (include `project.yml`).

---

### Task 6: Server controller and app wiring

**Files:**
- Create: `TuneNook/MCP/MCPServerController.swift`, `TuneNook/MCP/MCPConnectionSnippets.swift`
- Modify: `TuneNook/App/TuneNookApp.swift`
- Test: `TuneNookTests/MCPServerControllerTests.swift`

**Interfaces:**
- Consumes: `TuneNookTools`, `MCPServerFactory.makeServer`, `LoopbackHTTPServer`, `RequestGate`, SDK `StatelessHTTPServerTransport`.
- Produces:

```swift
@MainActor @Observable
final class MCPServerController {
    enum Status: Equatable { case off, starting, running(port: Int), failed(String) }
    static let defaultPort = 47821
    static let portRange = 1024...65535
    enum Key { static let enabled = "mcp.enabled"; static let port = "mcp.port"; static let token = "mcp.token" }

    init(tools: TuneNookTools, defaults: UserDefaults = .standard)
    private(set) var status: Status
    var isEnabled: Bool { get }          // persisted; false by default
    var port: Int { get }                // persisted; defaultPort by default
    private(set) var token: String       // "" until first enabled
    func setEnabled(_ enabled: Bool) async
    func setPort(_ port: Int) async      // ignores values outside portRange; restarts if enabled
    func regenerateToken() async         // new token; restarts if enabled
    func startIfEnabled() async          // called once at launch
}

enum MCPConnectionSnippets {
    static func url(port: Int) -> String                       // "http://127.0.0.1:<port>/mcp"
    static func claudeCodeCommand(port: Int, token: String) -> String
    static func jsonConfig(port: Int, token: String) -> String
}
```

- The token is 32 bytes from `SecRandomCopyBytes`, base64url without padding (43 characters), created the first time `setEnabled(true)` runs.
- Request path: `gate.rejection(for:)` first; otherwise `await transport.handleRequest(request)`. The transport keeps the SDK's default validation pipeline.
- Failure texts: `.portInUse` → `"Port <port> is in use by another app. Choose another port."`; anything else → `"Couldn't start the server."`. A failure never throws out of the controller.
- `claudeCodeCommand` is exactly:
  `claude mcp add --transport http tunenook http://127.0.0.1:<port>/mcp --header "Authorization: Bearer <token>"`
- `jsonConfig` is pretty-printed:
  `{"mcpServers": {"tunenook": {"type": "http", "url": "http://127.0.0.1:<port>/mcp", "headers": {"Authorization": "Bearer <token>"}}}}`
- `TuneNookApp.init`: build `TuneNookTools(context: container.mainContext, defaults: .standard, goalStore: goalStore, stations: RadioStation.bundled(), isBusy: { [weak engine] task in engine?.isTaskLocked == true && engine?.currentTask == task }, deselect: { [weak engine] task in if engine?.currentTask == task { engine?.currentTask = nil } })`, create the controller, keep it in `@State`, call `Task { await controller.startIfEnabled() }`, and add `.environment(mcpServer)` to the `Settings` scene.

- [ ] **Step 1: Write the failing tests** in `MCPServerControllerTests` (`@MainActor`, in-memory container, throwaway defaults suite, a random high port set through `setPort`):

- `offByDefaultWithNoToken`: `status == .off`, `isEnabled == false`, `token.isEmpty`; `startIfEnabled()` leaves it off.
- `enablingCreatesATokenAndRuns`: token has 43 characters, `status == .running(port:)`, and both are persisted under `Key`.
- `endToEndOverHTTP`: POST a JSON-RPC `initialize` to `/mcp` with the bearer header and `Accept: application/json` → 200; the same request without the header → 401; then `tools/list` returns 12 tools.
- `disablingStopsListening`: after `setEnabled(false)` a request fails to connect and `status == .off`.
- `regenerateInvalidatesTheOldToken`: the old token gets 401, the new one 200.
- `portInUseShowsFailureAndRecovers` (Review Focus 2): occupy the port with a bare `LoopbackHTTPServer`, enable → `status == .failed("Port … is in use by another app. Choose another port.")`; stop the squatter, `setEnabled(false)` then `true` → running.
- `outOfRangePortIsIgnored`: `setPort(80)` keeps the old port.
- `snippets`: `claudeCodeCommand(port: 47821, token: "test-token")` equals the exact string above; `jsonConfig` parses as JSON with that URL and header.

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** the controller and the snippets.
- [ ] **Step 4: Run to verify they pass.**
- [ ] **Step 5: Wire it into `TuneNookApp`** and run the whole suite:
`xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build test`. Expected: every suite passes.
- [ ] **Step 6: Commit** `feat(mcp): server controller and app wiring`.

---

### Task 7: Agents tab in Settings

**Files:**
- Create: `TuneNook/Views/Settings/AgentsSettingsTab.swift`
- Modify: `TuneNook/Views/Settings/SettingsView.swift` (add the tab after Rewards: `Label("Agents", systemImage: "point.3.connected.trianglepath.dotted")`)

**Interfaces:**
- Consumes: `MCPServerController` from the environment, `MCPConnectionSnippets`.

Layout, a grouped `Form` in the style of the other tabs (see the sketch in the spec):

- Section **MCP server**
  - Toggle `Let AI agents manage TuneNook` bound to `isEnabled` / `setEnabled`.
  - `Status`: `Off`, `Starting…`, `Running on 127.0.0.1:<port>` with a green dot, or the failure text in red.
  - `Port`: a number field; applies on submit through `setPort`; shows `Use a port from 1024 to 65535.` for other input.
  - `Token`: masked as dots, with **Copy** and **Regenerate**. Hidden until a token exists. Regenerate asks first: title `Regenerate the token?`, message `Connected agents stop working until you give them the new token.`, buttons `Regenerate` (destructive) and `Cancel`.
- Section **Connect a client**, shown only when a token exists
  - `Claude Code` → **Copy Command** (`claudeCodeCommand`).
  - `Other clients` → **Copy Config** (`jsonConfig`).
- Footer: `Agents can manage topics, tasks and settings and read your focus history. They can't control the timer or the radio. TuneNook must be running.`

Copy buttons write to `NSPasteboard.general` and show `Copied` for two seconds.

- [ ] **Step 1: Implement** the tab and add it to `SettingsView`.
- [ ] **Step 2: Build and run**

```bash
xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/TuneNook.app
```

- [ ] **Step 3: Check by hand** in Settings → Agents: the tab opens with the server off and no token; turning it on shows `Running on 127.0.0.1:47821`, a token row and the Connect section; **Copy Command** puts the `claude mcp add …` line on the clipboard; Regenerate asks, then the copied command carries a different token; turning it off shows `Off`. Then run `curl -i http://127.0.0.1:47821/mcp` while on → `401`.
- [ ] **Step 4: Commit** `feat(mcp): Agents settings tab`.

---

### Task 8: End-to-end check and docs

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Connect Claude Code to the debug build.** With the server on, run the copied `claude mcp add …` command, then in a Claude Code session with TuneNook's main window open:
  - Ask it to create a topic and three tasks → they appear in the window without a relaunch.
  - Start a focus session on one of them in the app, ask the agent to delete that task → it reports the refusal and the timer keeps running.
  - Ask it to set focus to 50 minutes → Settings → Timer shows 50.
  - Ask how much you focused this week → it answers from `get_progress`.
  - Quit and reopen Claude Code, ask for the topic list again → it works (Review Focus 1).
  - Remove the test server entry afterwards with `claude mcp remove tunenook` if it shouldn't stay.

  Report each result as passed or failed with what was seen. A failure here goes back to the task that owns the code.

- [ ] **Step 2: Update `README.md`**
  - Features: `- **Agents (MCP)** (v0.8): let Claude Code and other MCP clients manage your topics, tasks and settings and read your focus history. Off by default; turn it on in Settings → Agents. It listens on this Mac only and needs a token.`
  - A section `## Connect an agent` after Features: turn it on, copy the command, what agents can and can't do, that TuneNook must be running, and that Claude Desktop needs an HTTP bridge such as `mcp-remote`.
  - Roadmap: add `| **v0.8** ✅ | MCP server for agents |` and change the Later row to `macOS Focus Filters, iCloud sync, MCP client (pull tasks from other tools)`.
  - Development requirements: `Xcode 16+` → `Xcode 16.3+`.

- [ ] **Step 3: Run the whole suite once more.** Expected: every suite passes.
- [ ] **Step 4: Commit** `docs: MCP server`.
