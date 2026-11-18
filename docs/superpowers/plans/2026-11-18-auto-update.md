# In-app Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TuneNook checks for, downloads, verifies and installs new releases itself through Sparkle 2, without interrupting focus or losing a session.

**Architecture:** A pure `UpdateGate` value type holds the two timing rules: hold scheduled update UI during focus, and don't relaunch during an active session. It is unit-tested without Sparkle. `UpdaterController` wraps `SPUStandardUpdaterController`, feeds it timer state and exposes what SwiftUI binds to. Release CI signs the existing `.zip` with EdDSA and attaches a one-item `appcast.xml` to each GitHub Release. The feed URL is `releases/latest/download/appcast.xml`.

**Tech Stack:** Swift 6, SwiftUI, XcodeGen, Sparkle 2 (SPM), Swift Testing, GitHub Actions, bash.

**Spec:** `docs/superpowers/specs/2026-11-18-auto-update-design.md`

## Global Constraints

- Edit `project.yml`, never `TuneNook.xcodeproj`, `Info.plist` or the `.entitlements` file directly. Run `xcodegen generate` after each `project.yml` change.
- macOS 14.0 minimum, arm64 only, Swift 6 strict concurrency. App Sandbox, Hardened Runtime and ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`) all stay on.
- Feed URL: `https://github.com/vantoantrinh96/tunenook/releases/latest/download/appcast.xml`.
- Scheduled check interval: `86400`. Automatic checks are on by default (`SUEnableAutomaticChecks = YES`). Automatic download and install is off by default.
- Pin one Sparkle version (the latest stable 2.x on the day of Task 1) in both the SPM package (`exactVersion`) and CI (the tarball URL plus its SHA-256).
- The private EdDSA key exists only in the repo secret `SPARKLE_ED_PRIVATE_KEY` and in the owner's login keychain. It is never written to the repo, CI logs or a file left on disk.
- "Focus" means `phase == .focus` and the engine is active (running or paused). An "active session" means the engine is active, in any phase.
- User-facing copy: "Check for Updates…", "Check for updates automatically", "Download and install updates automatically", "TuneNook %@ is available", "TuneNook %@ will be installed when you quit TuneNook."
- Each run: `xcodebuild -scheme TuneNook -destination 'platform=macOS' -derivedDataPath build test` must pass before a commit.

## Review Focus

1. **Focus is stopped with Stop (`abandon`) instead of finishing.** A held update should appear as soon as the engine goes idle. Covered by `UpdateGateTests.focusEndingByAbandonShowsHeldUpdate` and the Task 3 manual check.
2. **A break runs, or focus is paused, when Install is clicked.** Neither should relaunch, because both count as active sessions. Covered by `UpdateGateTests.relaunchPostponedForBreakAndPausedFocus`.
3. **Release notes contain `<`, `&` or `]]>`.** The appcast must stay valid XML. Covered by `scripts/test-make-appcast.sh`.
4. **The feed returns 404 or the Mac is offline during a scheduled check** (for example in the seconds after a release is created, before `appcast.xml` is attached). Expected: no error dialog for scheduled checks. This is Sparkle's default; it gets a manual check in Task 5 by pointing `SUFeedURL` at a missing URL.
5. **A held update followed by a manual "Check for Updates…" during focus.** The manual check shows at once and clears the hold, so the window doesn't pop up a second time when focus ends. Covered by `UpdateGateTests.manualCheckClearsHold`.

---

### Task 1: Add Sparkle, keys and sandbox configuration

**Files:**
- Modify: `project.yml`

**Interfaces:**
- Produces: `import Sparkle` builds in the `TuneNook` and `TuneNookTests` targets. Info.plist has `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval` and `SUEnableInstallerLauncherService`. The repo secret `SPARKLE_ED_PRIVATE_KEY` exists. Later tasks use the `SPARKLE_VERSION` you pinned.

- [ ] **Step 1: Pick the version and generate keys.** In a new directory under the scratchpad, download `https://github.com/sparkle-project/Sparkle/releases/download/<SPARKLE_VERSION>/Sparkle-<SPARKLE_VERSION>.tar.xz`, record its `shasum -a 256` and extract it. Then:
  - Run `bin/generate_keys --account tunenook`. This creates the key in the login keychain, which is the owner's backup.
  - Run `bin/generate_keys --account tunenook -p` to print the public key.
  - Run `bin/generate_keys --account tunenook -x <scratch>/sparkle.key`, then `GH_TOKEN=$(gh auth token -u vantoantrinh96) gh secret set SPARKLE_ED_PRIVATE_KEY -R vantoantrinh96/tunenook < <scratch>/sparkle.key`, then `rm <scratch>/sparkle.key`.
  - Expected: `gh secret list` shows `SPARKLE_ED_PRIVATE_KEY`.
- [ ] **Step 2: Edit `project.yml`.**
  - Add a top-level `packages: Sparkle: {url: https://github.com/sparkle-project/Sparkle, exactVersion: <SPARKLE_VERSION>}`, and `dependencies: [{package: Sparkle}]` on the `TuneNook` target.
  - Add the five Info.plist keys under `info.properties` (public key from Step 1).
  - Add the entitlement `com.apple.security.temporary-exception.mach-lookup.global-name: ["$(PRODUCT_BUNDLE_IDENTIFIER)-spks", "$(PRODUCT_BUNDLE_IDENTIFIER)-spki"]`.
  - Add `SPARKLE_VERSION` and its tarball SHA-256 as comments next to the package, so CI (Task 4) uses the same values.
- [ ] **Step 3: Check that the Release build loads Sparkle under Hardened Runtime.**
  - Run `xcodegen generate && xcodebuild -scheme TuneNook -configuration Release -destination 'generic/platform=macOS' -derivedDataPath build build`.
  - Then run `build/Build/Products/Release/TuneNook.app/Contents/MacOS/TuneNook` for about 5 seconds.
  - Expected: no `dyld` / `Library not loaded` / "different Team IDs" error, and the app keeps running.
  - If it fails with the Team ID error, add `com.apple.security.cs.disable-library-validation: true` to the entitlements with a comment ("ad-hoc signing has no Team ID; Sparkle updates are verified by EdDSA"), regenerate, and re-check.
  - Also check `codesign --verify --deep --strict build/Build/Products/Release/TuneNook.app` → exits 0.
- [ ] **Step 4: Run the test suite.** Expected: PASS (no code uses Sparkle yet).
- [ ] **Step 5: Commit.** `build: add Sparkle 2 and update feed configuration`

### Task 2: `UpdateGate` timing rules

**Files:**
- Create: `TuneNook/System/UpdateGate.swift`
- Test: `TuneNookTests/UpdateGateTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct UpdateGate: Sendable {
      static func isFocusing(phase: SessionKind, isActive: Bool) -> Bool
      private(set) var isHoldingUpdate: Bool          // starts false
      /// A scheduled check found an update. Returns true if it may be shown now; otherwise holds it.
      mutating func scheduledUpdateFound(isFocusing: Bool) -> Bool
      /// Timer state changed. Returns true exactly once when a held update should now be shown.
      mutating func focusChanged(isFocusing: Bool) -> Bool
      /// The user asked for the update (menu, Settings or notification). Clears any hold.
      mutating func userRequestedUpdate()
      /// Whether Sparkle must not relaunch now (install on quit instead).
      static func shouldPostponeRelaunch(isActive: Bool) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests** in `UpdateGateTests` (Swift Testing, `@Test`):
  - `isFocusingOnlyInActiveFocus`: `isFocusing(.focus, true) == true`; `(.focus, false) == false`; `(.shortBreak, true) == false`; `(.longBreak, true) == false`.
  - `scheduledUpdateOutsideFocusShowsNow`: `scheduledUpdateFound(isFocusing: false) == true`, `isHoldingUpdate == false`.
  - `scheduledUpdateDuringFocusIsHeldUntilFocusEnds`: `scheduledUpdateFound(isFocusing: true) == false`, `isHoldingUpdate == true`; `focusChanged(isFocusing: true) == false`; `focusChanged(isFocusing: false) == true`, `isHoldingUpdate == false`; a second `focusChanged(isFocusing: false) == false`.
  - `focusEndingByAbandonShowsHeldUpdate`: use a real `TimerEngine` (built like `TimerEngineTests.makeEngine`). `start()`; held via `scheduledUpdateFound(isFocusing: isFocusing(engine.phase, engine.isActive))`; `engine.abandon()`; `focusChanged(isFocusing: isFocusing(engine.phase, engine.isActive)) == true`.
  - `manualCheckClearsHold`: hold an update, then `userRequestedUpdate()`, then `focusChanged(isFocusing: false) == false`.
  - `relaunchPostponedForBreakAndPausedFocus`: `shouldPostponeRelaunch(isActive: true) == true`, `(isActive: false) == false`. Then with a real engine: after `start(); pause()`, `engine.isActive == true`; and the same after the focus completes into an auto-started break (`TimerSettings(autoStartBreaks: true, …)`, advance 25 min, `tick()`).
- [ ] **Step 2: Run the tests.** `xcodebuild … test -only-testing:TuneNookTests/UpdateGateTests`. Expected: FAIL (`cannot find 'UpdateGate'`).
- [ ] **Step 3: Implement `UpdateGate`.** Plain value type, no Sparkle import.
- [ ] **Step 4: Run the tests.** Expected: PASS. Then run the full suite. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(updates): add rules for when update UI may show`

### Task 3: `UpdaterController`, notifications and UI

**Files:**
- Create: `TuneNook/System/UpdaterController.swift`
- Modify: `TuneNook/Notifications/NotificationService.swift`, `TuneNook/App/TuneNookApp.swift`, `TuneNook/Views/MenuBar/MenuBarView.swift` (`footer`), `TuneNook/Views/Settings/SettingsView.swift` (`GeneralSettingsTab`)

**Interfaces:**
- Consumes: `UpdateGate` (Task 2); `TimerEngine.phase`, `TimerEngine.isActive`.
- Produces:
  ```swift
  @MainActor @Observable
  final class UpdaterController: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
      init(engine: TimerEngine, notifications: NotificationService)
      private(set) var canCheckForUpdates: Bool
      var automaticallyChecksForUpdates: Bool      // get/set through to SPUUpdater
      var automaticallyDownloadsUpdates: Bool      // get/set through to SPUUpdater
      var versionDescription: String              // "0.7.0 (7)" from the bundle
      func checkForUpdates()                       // calls gate.userRequestedUpdate(), then updater.checkForUpdates()
  }
  ```
  `NotificationService` gains `func notifyUpdateAvailable(version: String)` (id `tunenook.update`), `func notifyUpdateOnQuit(version: String)` (id `tunenook.update-on-quit`) and `var onShowUpdateRequested: (() -> Void)?`. The callback fires when the user clicks the `tunenook.update` notification (default action).

- [ ] **Step 1: Notifications.** Add the two methods with the copy from Global Constraints. Extend `didReceive` so the default action on `tunenook.update` calls `onShowUpdateRequested` on the main actor. The existing Resume Focus handling stays as it is.
- [ ] **Step 2: `UpdaterController`.**
  - Create `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)`.
  - Mirror `canCheckForUpdates` through KVO on `updater.canCheckForUpdates`.
  - Gentle reminders: `supportsGentleScheduledUpdateReminders` → `true`. `standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` → `gate.scheduledUpdateFound(isFocusing:)`. In `standardUserDriverWillHandleShowingUpdate(_:forUpdate:state:)`, when `handleShowingUpdate == false`, call `notifications.notifyUpdateAvailable(version: update.displayVersionString)`.
  - Watch the engine with `withObservationTracking` on `engine.phase` and `engine.isActive`, re-registering after each change. When `gate.focusChanged(...)` returns true, call `checkForUpdates()` (Sparkle's documented way to bring a held update forward).
  - `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`: if `UpdateGate.shouldPostponeRelaunch(isActive: engine.isActive)`, keep the block, call `notifyUpdateOnQuit` and return `true`, so the update installs when the app quits. Otherwise return `false`.
  - `notifications.onShowUpdateRequested = { [weak self] in self?.checkForUpdates() }`.
- [ ] **Step 3: Wire up the controller.** Create it in `TuneNookApp.init` after `engine` and `notifications`, store it as `@State`, and pass it with `.environment(updater)` to `MenuBarView` and `SettingsView`.
- [ ] **Step 4: Popover footer.** Add a borderless icon button (`arrow.down.circle`, `.help("Check for Updates…")`) before the Settings link. It is disabled when `!canCheckForUpdates` and calls `activateApp()` then `checkForUpdates()`.
- [ ] **Step 5: Settings → General.** Add a new `Section` with header "Updates" after "When you step away". It contains:
  - Toggle "Check for updates automatically".
  - Toggle "Download and install updates automatically", disabled when automatic checks are off.
  - `LabeledContent("Version", value: versionDescription)` with a trailing "Check Now" button.
  - Footer: "Updates are verified before they're installed. If a timer is running, the update waits until you quit TuneNook."
- [ ] **Step 6: Build, test and smoke-run.**
  - Full test suite. Expected: PASS.
  - Launch the Debug app, open the popover and click the new button. Expected: Sparkle's checking window appears. It shows an error until the first appcast exists (the feed URL 404s), which is fine for a manual check.
  - Open Settings → General. Expected: the Updates section shows the version, and the toggles change `defaults read io.github.vantoantrinh96.tunenook SUEnableAutomaticChecks` / `SUAutomaticallyUpdate`.
- [ ] **Step 7: Commit.** `feat(updates): check for and install updates in the app`

### Task 4: Appcast in the release workflow

**Files:**
- Create: `scripts/make-appcast.sh`, `scripts/test-make-appcast.sh`
- Modify: `scripts/release.sh` (expose the build number), `.github/workflows/release.yml` (`build` job), `.github/workflows/ci.yml` (`test` job)

**Interfaces:**
- Produces:
  - `scripts/release.sh build` prints `CURRENT_PROJECT_VERSION` (the existing `build_number` function, added to the `case`, with the usage comment updated).
  - `scripts/make-appcast.sh <version> <build> <zip-url> <release-url> <signature-attrs> <notes-file>` writes `appcast.xml` to stdout. `<signature-attrs>` is `sign_update`'s output verbatim (`sparkle:edSignature="…" length="…"`).

- [ ] **Step 1: Write the failing script test** `scripts/test-make-appcast.sh` (bash, `set -euo pipefail`). It writes a notes file containing `Fixes <b> & "quotes" ]]> done` and runs `make-appcast.sh 1.2.3 42 https://example.com/T.zip https://example.com/rel 'sparkle:edSignature="abc" length="10"' notes`. It asserts:
  - `xmllint --noout` passes.
  - `xmllint --xpath` finds `sparkle:version` = `42`, `sparkle:shortVersionString` = `1.2.3`, `sparkle:minimumSystemVersion` = `14.0` and the enclosure `url` = the zip URL, with `sparkle:edSignature="abc"`.
  - The description text round-trips and contains `]]>`.
- [ ] **Step 2: Run it.** Expected: FAIL (script missing).
- [ ] **Step 3: Implement `make-appcast.sh`.**
  - Emit an RSS 2.0 document with the Sparkle namespace and one `<item>` (title `TuneNook <version>`, `<link>` = release URL, `pubDate` in RFC 822).
  - Put the notes in `<description>` inside CDATA, with every `]]>` split as `]]]]><![CDATA[>`. Use `sparkle:format="markdown"` if the pinned Sparkle version documents it, else `plain-text`.
- [ ] **Step 4: Run it.** Expected: PASS. Add `scripts/test-make-appcast.sh` as a step in the `ci.yml` `test` job, before Test.
- [ ] **Step 5: Edit the `build` job in `release.yml`.** After "Publish GitHub Release", add a step "Publish appcast" with `env: SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}`. It does the following:
  - Downloads the pinned tarball and checks it with `shasum -a 256 -c`.
  - Signs with `printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | bin/sign_update --ed-key-file - "TuneNook-$VERSION.zip"`.
  - Gets the notes with `gh release view "v$VERSION" --json body -q .body`.
  - Calls `make-appcast.sh` with `build=$(scripts/release.sh build)`, the zip URL `https://github.com/$REPO/releases/download/v$VERSION/TuneNook-$VERSION.zip` and the release URL `https://github.com/$REPO/releases/tag/v$VERSION`.
  - Runs `gh release upload "v$VERSION" appcast.xml`.
  - Writes a line to `$GITHUB_STEP_SUMMARY`.
  - It fails if the secret is empty.
- [ ] **Step 6: Lint the workflow.** Run `actionlint .github/workflows/*.yml` if available (`brew install actionlint`). Expected: no errors.
- [ ] **Step 7: Commit.** `ci: publish a signed Sparkle appcast with each release`

### Task 5: End-to-end update test and docs

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Local end-to-end run.** All of this happens in a scratchpad directory, and nothing is committed.
  1. Build Release as **N** (current version) and copy it to `<scratch>/new/TuneNook.app`. Zip it with `ditto -c -k --keepParent`. Sign it with `generate_keys`' keychain key (`bin/sign_update <zip>`, no `--ed-key-file`). Write `appcast.xml` with `make-appcast.sh` using a build number higher than the installed one and a `http://localhost:8000/…` URL. Serve the directory with `python3 -m http.server 8000`.
  2. Install a Release build with a lower `CURRENT_PROJECT_VERSION` into `/Applications`. Pass it on the `xcodebuild` command line; don't edit `project.yml`. Then run `defaults write io.github.vantoantrinh96.tunenook SUFeedURL http://localhost:8000/appcast.xml`.
  3. Idle timer → Check for Updates… → dialog with notes → Install and Relaunch. Expected: the app relaunches and Settings shows the new build.
  4. Reinstall the old build and start focus → Check for Updates… → Install. Expected: no relaunch and the "will be installed when you quit" notification. Quit → reopen. Expected: the new build.
  5. Reinstall the old build, start focus and trigger a scheduled check (`defaults write … SULastCheckTime -date 2000-01-01` and relaunch). Expected: no window and the "is available" notification. Stop focus. Expected: the update window appears.
  6. Point `SUFeedURL` at `http://localhost:8000/missing.xml` and trigger a scheduled check. Expected: no error dialog.
  7. Clean up: `defaults delete io.github.vantoantrinh96.tunenook SUFeedURL`, stop the server, and reinstall the build you normally use.
- [ ] **Step 2: README.**
  - Add a Features bullet: "**In-app updates** (v0.7): TuneNook checks GitHub for a new version once a day and installs it in one click. Updates are signed and verified, never interrupt a focus session, and wait until you quit if a timer is running. Check by hand from the popover or Settings → General."
  - In "Versioning", describe the appcast, the `SPARKLE_ED_PRIVATE_KEY` secret (backup in the owner's login keychain under account `tunenook`), and the one-time manual install of the first version that has updates.
- [ ] **Step 3: Commit.** `docs: describe in-app updates`
