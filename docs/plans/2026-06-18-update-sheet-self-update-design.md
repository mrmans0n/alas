# Inline self-update from the update available sheet

## Goal

When Alas detects a newer release and the running copy was installed via Homebrew, the update sheet should offer an **inline “Update” button** that runs `brew upgrade --cask alas` as a subprocess inside a progress/log sheet. This matches the existing `LSPInstallProgressSheet` pattern and lets users upgrade without leaving the app.

## Background

- The current `UpdateAvailableSheet` shows `brew upgrade --cask alas` as a read-only, copyable command for Homebrew installs.
- `LSPInstallProgressSheet` + `LSPInstaller` already demonstrate how to spawn a subprocess, stream stdout/stderr, and present live logs inside a sheet.
- The Alas cask (`mrmans0n/homebrew-tap/Casks/alas.rb`) has no `quit`/`signal` uninstall stanzas and no `on_upgrade` directive, so Homebrew will **not** terminate the running app during the upgrade.
- On macOS, deleting a running app bundle generally succeeds: the running executable stays memory-mapped until it exits. The next Alas launch uses the new bundle.

## Non-goals

- No automatic app relaunch after a successful update.
- No support for direct-download installs (those keep the existing View Release / Download / Later buttons).
- No long-running background update service.

## Components

### `SelfUpdater`

A new `@MainActor @Observable` model in the `Updates` module.

```swift
enum State: Equatable, Sendable {
    case idle
    case running(commandLine: String)
    case finished(exitCode: Int32)
    case cancelled
    case failed(message: String)
}
```

- `private(set) var state: State`
- `private(set) var logLines: [String]`
- `func start(command: BrewCommand)` — starts `brew` as a subprocess.
- `func cancel()` — SIGINT → SIGTERM → SIGKILL escalation, identical to `LSPInstaller`.
- `func reset()` — hard kill + clear state, used when the sheet is dismissed mid-run.

`BrewCommand` is a small struct holding the executable and full argv; for now it is always `brew upgrade --cask alas`, but wrapping it keeps `SelfUpdater` testable and avoids magic strings in the view.

The spawn implementation reuses the `Process` + `Pipe` + `LineBuffer` pattern from `LSPInstaller`. Because `SelfUpdater` only ever runs one update per app launch, the generation-token concurrency guard can be simplified or omitted; cancellation/reset still protects against stale `terminationHandler` callbacks by tracking the current `Process` instance.

### `UpdateProgressSheet`

A new view in the `Updates` module, structurally similar to `LSPInstallProgressSheet` but smaller:

- Title changes with `SelfUpdater.State`.
- A read-only monospaced command line when running.
- A live log scroll view.
- Buttons:
  - Running: **Cancel**.
  - Finished/cancelled/failed: **Close**.
  - Success (exit code 0): optionally **Done** to match `LSPInstallProgressSheet`, with the same dismissal semantics so the caller can re-check if needed.

On success, a short explanation is shown:
> “Update downloaded. Quit and reopen Alas to start the new version.”

### `UpdateAvailableSheet` changes

For `.homebrew` installs the action row becomes:
- Read-only command: `brew upgrade --cask alas`
- **Update** (primary) — triggers the progress sheet
- **Copy** — copies the command to the clipboard
- **Later** — dismisses

The sheet gains a new closure: `let onRunUpdate: () -> Void`.

### `RootView` changes

The current `.sheet(item: $state.updateController.presentedUpdate)` presents `UpdateAvailableSheet`. We keep that sheet as the entry point, but add a second sheet layer triggered from the update sheet:

```swift
UpdateAvailableSheet(
    info: info,
    source: state.updateController.source,
    onDismiss: { state.updateController.presentedUpdate = nil },
    onRunUpdate: { state.presentUpdateProgress = true }
)
.sheet(isPresented: $state.presentUpdateProgress) {
    UpdateProgressSheet(updater: state.selfUpdater) {
        state.presentUpdateProgress = false
        // Optionally clear presentedUpdate so the update sheet doesn't come back until next check.
    }
}
```

`AppState` owns the new `SelfUpdater` instance.

### `AppState` changes

- Add `let selfUpdater = SelfUpdater()` next to `lspInstaller`.
- Add `@Published var presentUpdateProgress: Bool = false` or a similar presentation flag.

## Error handling and edge cases

| Scenario | Behavior |
|---|---|
| `brew` not on PATH | `process.run()` fails → `.failed(message:)` |
| Network or cask error | `brew` exits non-zero → `.finished(exitCode: nonzero)` |
| User clicks Cancel | SIGINT, then escalate to SIGTERM/SIGKILL → `.cancelled` |
| Sheet closed mid-run | `reset()` kills the process and clears state |
| Second update check while one is running | Button disabled via `state == .idle` guard |
| Successful exit code 0 | Show the quit/reopen explanation; do not auto-quit |

Because Alas keeps running after the bundle is replaced, we do **not** try to verify the new version from inside the process. The success message is phrased defensively.

## Testing

- Unit tests for `SelfUpdater` using a test seam (`_spawnForTesting`) with `/bin/echo` and `/bin/sleep`, mirroring `LSPInstaller` tests:
  - state transitions from `.idle` to `.running` to `.finished(0)`
  - log lines are captured
  - cancellation transitions to `.cancelled`
  - reset kills a running process
- UI tests are not required; the sheet layout is straightforward and covered by SwiftUI previews if convenient.

## Verification plan

1. Run `xcodegen`.
2. Run `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' build`.
3. Run `xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test`.
4. Manual test: temporarily lower the hardcoded/current version, trigger “Check for Updates…”, and click **Update**. Confirm `brew upgrade --cask alas` runs to completion and the app remains usable.

## Open questions

- Should the update sheet stay dismissed after a successful update, or re-appear on the next manual check until Alas is relaunched? Proposed: dismiss it after Update is clicked; on next check it will report up-to-date for the running version.
