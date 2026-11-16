# TuneNook ♪

A cozy focus nook in your macOS menu bar: a task-driven focus timer with built-in radio.

*Tune in. Get it done.*

## Features

- **Menu bar timer**: time left shows in the menu bar. Start, pause, resume, stop and skip from a popover. Press Space to start or pause.
- **Topics & tasks**: group to-dos by topic, estimate focus sessions per task and track actual against estimate.
- **Focus cycle**: focus, short break and a long break every N sessions (Pomodoro-style by default), all configurable. Breaks can start automatically.
- **Focus Radio**: one-click internet radio from [SomaFM](https://somafm.com).
- **Notifications** when a phase ends. They are scheduled ahead of time, so they fire even when the app is idle.
- **Daily goal & streaks** (v0.2): set a daily target in focus minutes or sessions. Meeting it grows your streak, and every 7-day streak earns a freeze (max 2) that covers a missed day. You can set when a new day starts, for night owls.
- **Progress page** (v0.2): today's ring, current and best streak, freezes, last 7 days, a GitHub-style heatmap of focus history and deadline pacing per topic (sessions per day needed).
- **Celebrations** (v0.3): confetti when you reach your daily goal, hit a streak milestone (3, 7, 14, 30… days) or unlock an icon. Set it to off, milestones only or every session. It respects Reduce Motion.
- **Unlockable menu bar icons** (v0.3): 10 icons earned by sessions finished, best streak and goal days. Pick one in Settings → Rewards or on the Progress page.
- **Smart music rules** (v0.3): on a break, keep playing, lower the volume, stop or switch to a break station. Pausing the timer pauses the music and resuming continues it; stopping the timer stops it. Music never starts by itself; you press play.
- **Sleep-proof**: remaining time comes from an end date, so the timer catches up correctly after sleep.

## Roadmap

| Phase | Scope |
|---|---|
| **MVP** ✅ | Menu bar timer, topic/task CRUD, estimate vs actual, notifications, radio |
| **v0.2** ✅ | Daily targets, streaks with freezes, GitHub-style heatmap, deadline pacing |
| **v0.3** ✅ | Celebration animations, unlockable menu bar icons, smart music rules (pause or switch on breaks) |
| Later | Stats & estimate accuracy, macOS Focus Filters, iCloud sync, remote station list |

## Development

Requirements: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate           # creates TuneNook.xcodeproj from project.yml
open TuneNook.xcodeproj
```

From the command line:

```sh
xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build build
xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build test
open build/Build/Products/Debug/TuneNook.app
```

The Xcode project, `Info.plist` and entitlements are generated, so edit `project.yml` instead.

## Workflow & CI

`main` only changes through pull requests. After cloning, turn on the repo's git hooks once:

```sh
git config core.hooksPath .githooks   # pre-push hook blocks direct pushes to main
```

Work on a branch, push it and open a pull request into `main`. PRs merge with a merge commit (squash and rebase merges are off).

[CI](.github/workflows/ci.yml) runs on every pull request into `main` and again after the merge:

1. **Security scan** (Linux): [Gitleaks](https://github.com/gitleaks/gitleaks) checks the whole git history for secrets, and [Semgrep](https://semgrep.dev) checks the code with the Swift, secrets and GitHub Actions rule packs.
2. **Build & test** (macOS, runs only if the scan passes): generates the project with XcodeGen, then builds and runs the test suite.

Changes that only touch Markdown skip CI. The repo is private on GitHub Free, so GitHub can't enforce branch rules on the server. The hook is the guard, and `git push --no-verify` gets past it.

## Structure

```
TuneNook/
  App/            App entry, scenes, SessionCoordinator (timer events → data, rewards, music)
  Models/         SwiftData models: Topic, TodoTask, FocusSession
  Timer/          TimerEngine (state machine) and TimerSettings
  Progress/       Daily goals, focus-day calendar, streak & heatmap stats
  Rewards/        Icon unlocks, celebration rules and the overlay
  Audio/          RadioPlayer (AVPlayer), stations and music rules
  Notifications/  Phase-end notifications
  Views/          Menu bar popover, main window, progress page, settings
  Resources/      stations.json
TuneNookTests/    Timer, streak, reward and music rule tests (Swift Testing)
```

Streaks and the heatmap are derived from `FocusSession` rows, so there is a single source of truth. Goal changes are stored as a history, so raising the goal today never rewrites past days.
