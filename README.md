# Tomatune 🍅♪

A task-driven Pomodoro timer that lives in the macOS menu bar, with built-in focus radio.

*Focus, one tomato at a time.*

## Features (MVP)

- **Menu bar timer**: time left shows in the menu bar. Start, pause, resume, stop and skip from a popover. Press Space to start or pause.
- **Topics & tasks**: group to-dos by topic, estimate pomodoros per task and track actual against estimate.
- **Focus cycle**: focus, short break and a long break every N pomodoros, all configurable. Breaks can start automatically.
- **Focus Radio**: one-click internet radio from [SomaFM](https://somafm.com). Can start automatically with each focus session.
- **Notifications** when a phase ends. They are scheduled ahead of time, so they fire even when the app is idle.
- **Sleep-proof**: remaining time comes from an end date, so the timer catches up correctly after sleep.

## Roadmap

| Phase | Scope |
|---|---|
| **MVP** ✅ | Menu bar timer, topic/task CRUD, estimate vs actual, notifications, radio |
| v0.2 | Daily targets, streaks, GitHub-style heatmap |
| v0.3 | Celebration animations, unlockable menu bar icons, smart music rules (pause or switch on breaks) |
| Later | Stats & estimate accuracy, macOS Focus Filters, iCloud sync, remote station list |

## Development

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate           # creates Tomatune.xcodeproj from project.yml
open Tomatune.xcodeproj
```

From the command line:

```sh
xcodebuild -scheme Tomatune -destination 'platform=macOS' -derivedDataPath build build
xcodebuild -scheme Tomatune -destination 'platform=macOS' -derivedDataPath build test
open build/Build/Products/Debug/Tomatune.app
```

The Xcode project, `Info.plist` and entitlements are generated, so edit `project.yml` instead.

## Structure

```
Tomatune/
  App/            App entry, scenes, wiring
  Models/         SwiftData models: Topic, TodoTask, FocusSession
  Timer/          TimerEngine (state machine) and TimerSettings
  Audio/          RadioPlayer (AVPlayer) and stations
  Notifications/  Phase-end notifications
  Views/          Menu bar popover, main window, settings
  Resources/      stations.json
TomatuneTests/    Timer engine tests (Swift Testing)
```

Streaks and the heatmap in v0.2 will be derived from `FocusSession` rows, so there is a single source of truth.
