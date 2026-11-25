# New-Task Deadline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick a deadline on the new-task bar while creating a task.

**Architecture:** A pure `DeadlinePreset` helper computes quick-pick dates and the chip's short label (unit tested). `NewTaskBar` in `TaskListView.swift` gets a calendar button that opens a popover with quick picks, a graphical date picker and "No deadline"; the chosen day is passed to `TodoTask(init:deadline:)` and reset after Add.

**Tech Stack:** Swift 6, SwiftUI (macOS 14), SwiftData, Swift Testing, XcodeGen (`TuneNook.xcodeproj` is git-ignored; run `xcodegen generate` after adding files).

**Spec:** `docs/superpowers/specs/2026-11-25-new-task-deadline-design.md`

## Global Constraints

- macOS 14.0 deployment target; no new dependencies.
- Deadline is stored as `Calendar.current.startOfDay(for:)` of the chosen day.
- Quick picks, in order: **Today**, **Tomorrow**, **Next week** (= the first Monday strictly after today).
- Date picker allows today onwards only.
- Chip label: "Today", "Tomorrow", otherwise `month(.abbreviated).day()` e.g. "Nov 28".
- No deadline is set unless the user picks one; after Add the deadline resets to none.
- No changes to `TaskEditor`, context menu, model, sync or MCP.

## Review Focus

- Picking "Next week" on a Monday → Monday 7 days later, not today. (Task 1 test)
- Picking "Next week" on a Sunday → the next day (Monday). (Task 1 test)
- Chip still shows a correct label if the app stays open past midnight (chosen "Today" becomes yesterday) — label is computed from `now` at render, so it shows the date, not a stale "Today". (Task 1 test: label for yesterday is a date)
- Enter in the title field adds the task with the chosen deadline (same `add()` path as the button). (Task 2 manual check)
- Clearing via ✕ then Add → task has no deadline. (Task 2 manual check)

---

### Task 1: `DeadlinePreset` helper

**Files:**
- Create: `TuneNook/Models/DeadlinePreset.swift`
- Test: `TuneNookTests/DeadlinePresetTests.swift`

**Interfaces:**
- Produces:
  - `enum DeadlinePreset: CaseIterable { case today, tomorrow, nextWeek }`
  - `var title: String` → "Today" / "Tomorrow" / "Next week"
  - `func date(from now: Date, calendar: Calendar = .current) -> Date` → start of the target day
  - `static func shortLabel(for day: Date, now: Date = .now, calendar: Calendar = .current) -> String`

- [ ] **Step 1: Write the failing tests** in `DeadlinePresetTests.swift` (`@Suite struct DeadlinePresetTests`, fixed `Calendar(identifier: .gregorian)` with `timeZone = TimeZone(identifier: "UTC")!`, dates built via `DateComponents`):
  - `todayIsStartOfToday`: now = Wed 2026-11-25 15:30 → `.today` == 2026-11-25 00:00
  - `tomorrowIsStartOfNextDay`: same now → `.tomorrow` == 2026-11-26 00:00
  - `nextWeekFromWednesdayIsNextMonday`: → 2026-11-30 00:00
  - `nextWeekFromMondayIsSevenDaysLater`: now = Mon 2026-11-30 09:00 → 2026-12-07 00:00
  - `nextWeekFromSundayIsTomorrow`: now = Sun 2026-11-29 22:00 → 2026-11-30 00:00
  - `shortLabelTodayTomorrowAndDate`: day = today → "Today"; tomorrow → "Tomorrow"; 2026-11-28 → "Nov 28"; 2026-11-24 (yesterday) → "Nov 24"
  (For the "Nov 28" assertions use a calendar whose `locale = Locale(identifier: "en_US")` and format with that calendar's locale/timeZone.)

- [ ] **Step 2: Run** `xcodegen generate && xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build test -only-testing:TuneNookTests/DeadlinePresetTests` — Expected: build FAIL, `DeadlinePreset` not found.

- [ ] **Step 3: Implement** `DeadlinePreset.swift`. Next week: `calendar.nextDate(after: startOfToday, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)`. `shortLabel` uses `calendar.isDate(_:inSameDayAs:)` against `now` / now+1 day, else `day.formatted(Date.FormatStyle(date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())`.

- [ ] **Step 4: Run** the same command — Expected: all `DeadlinePresetTests` PASS.

- [ ] **Step 5: Commit**
```bash
git add TuneNook/Models/DeadlinePreset.swift TuneNookTests/DeadlinePresetTests.swift
git commit -m "feat(tasks): add deadline quick-pick helper"
```

### Task 2: Deadline button on the new-task bar

**Files:**
- Modify: `TuneNook/Views/Main/TaskListView.swift` (`NewTaskBar`, lines ~69–108)

**Interfaces:**
- Consumes: `DeadlinePreset` (`allCases`, `title`, `date(from:)`, `shortLabel(for:)`); `TodoTask(title:estimatedSessions:topic:deadline:)`.

- [ ] **Step 1: Add state to `NewTaskBar`:** `@State private var deadline: Date?`, `@State private var pickingDeadline = false`.

- [ ] **Step 2: Add a private `DeadlineButton` view** (in the same file) taking `@Binding var deadline: Date?` and `@Binding var isPresented: Bool`:
  - Empty: `Button { isPresented = true } label: { Image(systemName: "calendar") }`, `.help("Deadline")`.
  - Set: chip `Label(DeadlinePreset.shortLabel(for: deadline), systemImage: "calendar")` that opens the popover, plus an `xmark.circle.fill` borderless button that sets `deadline = nil` (`.help("Remove deadline")`).
  - `.popover(isPresented:)` content, padded, `VStack`:
    - `HStack` of `DeadlinePreset.allCases` buttons → `deadline = preset.date(from: .now); isPresented = false`.
    - `DatePicker("", selection: <Binding get: deadline ?? today, set: startOfDay>, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()` — stays open.
    - If `deadline != nil`: `Button("No deadline") { deadline = nil; isPresented = false }`.

- [ ] **Step 3: Place it** in `NewTaskBar`'s `HStack` between the `TextField` and the `Stepper`.

- [ ] **Step 4: Wire `add()`:** pass `deadline: deadline` to `TodoTask(...)`; after save reset `deadline = nil` alongside `title`/`estimate`.

- [ ] **Step 5: Build + full tests:** `xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build test` — Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Manual check in the running app:** pick Tomorrow → chip "Tomorrow"; type title + Enter → row shows "Due tomorrow", chip resets to icon; pick a date on the calendar → chip shows it, popover stays open; ✕ then Add → no due label; past dates disabled in the calendar.

- [ ] **Step 7: Commit**
```bash
git add TuneNook/Views/Main/TaskListView.swift
git commit -m "feat(tasks): set a deadline while adding a task"
```
