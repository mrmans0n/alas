# Inline self-update implementation plan

> **REQUIRED SUB-SKILL:** Use the executing-plans skill to implement this plan task-by-task.

**Goal:** Add an inline “Update” button to `UpdateAvailableSheet` for Homebrew installs that runs `brew upgrade --cask alas` in a progress/log sheet, reusing the existing `LSPInstallProgressSheet` pattern.

**Architecture:** A new `@MainActor @Observable` `SelfUpdater` model spawns and streams `brew` output; a new `UpdateProgressSheet` presents it; `UpdateAvailableSheet` and `RootView` are wired to start and dismiss the flow. `.direct` installs remain unchanged.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Testing, `Foundation.Process`.

---

## Task 1: Create `SelfUpdater` model

**Files:**
- Create: `Alas/Sources/Updates/SelfUpdater.swift`
- Test: `AlasTests/Updates/SelfUpdaterTests.swift` (create directory)

**Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Alas

@Suite("SelfUpdater")
struct SelfUpdaterTests {
    @Test("echo transitions idle → running → finished(0)")
    @MainActor
    func echoSucceeds() async throws {
        let updater = SelfUpdater()
        await updater.runForTesting(executable: "/bin/echo", arguments: ["updated"])

        for _ in 0..<50 {
            if case .finished = updater.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        if case .finished(let code) = updater.state {
            #expect(code == 0)
        } else {
            Issue.record("expected finished, got \(updater.state)")
        }
        #expect(updater.logLines.joined(separator: "\n").contains("updated"))
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
cd /Users/nacho/.alas/.worktrees/alas/nacho-update-button/.worktrees/self-update
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/SelfUpdaterTests/echoSucceeds test -quiet 2>&1 | tail -20
```

Expected: FAIL with `Cannot find 'SelfUpdater' in scope`.

**Step 3: Write minimal implementation**

```swift
import Foundation
import Observation

/// Command shape for a self-update operation. For now this is always
/// `brew upgrade --cask alas`, but wrapping it makes `SelfUpdater` testable
/// and avoids scattering the command across views.
struct SelfUpdateCommand: Equatable, Sendable {
    let executable: String
    let arguments: [String]

    static let homebrew = SelfUpdateCommand(
        executable: "/opt/homebrew/bin/brew",
        arguments: ["upgrade", "--cask", "alas"]
    )

    var displayCommandLine: String {
        ((executable as NSString).lastPathComponent as String) + " " + arguments.joined(separator: " ")
    }
}

@Observable
@MainActor
final class SelfUpdater {
    enum State: Equatable, Sendable {
        case idle
        case running(commandLine: String)
        case finished(exitCode: Int32)
        case cancelled
        case failed(message: String)
    }

    private(set) var state: State = .idle
    private(set) var logLines: [String] = []

    private var currentProcess: Process?
    private var watchdog: Task<Void, Never>?
    private var cancelRequested = false

    /// Start the update. Requires `.idle`; otherwise throws.
    func start(command: SelfUpdateCommand) async throws {
        guard state == .idle else {
            throw SelfUpdaterBusy()
        }
        await _spawn(
            executable: command.executable,
            arguments: command.arguments,
            commandLineForDisplay: command.displayCommandLine
        )
    }

    func cancel() {
        guard case .running = state, let process = currentProcess else { return }
        cancelRequested = true
        kill(process.processIdentifier, SIGINT)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            await MainActor.run {
                if case .running = self.state, let proc = self.currentProcess, proc.isRunning {
                    proc.terminate()
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                if case .running = self.state, let proc = self.currentProcess, proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
    }

    func reset() {
        if case .running = state, let proc = currentProcess, proc.isRunning {
            cancelRequested = true
            kill(proc.processIdentifier, SIGKILL)
        }
        state = .idle
        logLines = []
        currentProcess = nil
        watchdog?.cancel()
        watchdog = nil
        cancelRequested = false
    }

    /// Test seam: spawn a command directly without going through `start`.
    func runForTesting(executable: String, arguments: [String]) async {
        precondition(state == .idle, "runForTesting requires idle state")
        await _spawn(
            executable: executable,
            arguments: arguments,
            commandLineForDisplay: ([executable] + arguments).joined(separator: " ")
        )
    }

    // MARK: - Private spawn

    private func _spawn(
        executable: String,
        arguments: [String],
        commandLineForDisplay: String
    ) async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH(base: env["PATH"])
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            let lines = buffer.feed(chunk)
            if lines.isEmpty { return }
            Task { @MainActor [weak self] in
                self?.logLines.append(contentsOf: lines)
            }
        }

        process.terminationHandler = { [weak self, buffer, pipe] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let finalData = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            let finalLines: [String]
            if let chunk = String(data: finalData, encoding: .utf8), !chunk.isEmpty {
                finalLines = buffer.feed(chunk)
            } else {
                finalLines = []
            }
            let finalTrailing = buffer.flush()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !finalLines.isEmpty {
                    self.logLines.append(contentsOf: finalLines)
                }
                if let trailing = finalTrailing, !trailing.isEmpty {
                    self.logLines.append(trailing)
                }
                self.currentProcess = nil
                self.watchdog?.cancel()
                self.watchdog = nil
                defer { self.cancelRequested = false }
                if case .running = self.state {
                    if proc.terminationStatus == 0 {
                        self.state = .finished(exitCode: 0)
                    } else if self.cancelRequested || proc.terminationReason == .uncaughtSignal {
                        self.state = .cancelled
                    } else {
                        self.state = .finished(exitCode: proc.terminationStatus)
                    }
                }
            }
        }

        state = .running(commandLine: commandLineForDisplay)
        logLines = []
        currentProcess = process

        do {
            try process.run()
        } catch {
            state = .failed(message: String(describing: error))
            currentProcess = nil
            return
        }

        try? stdinPipe.fileHandleForReading.close()
        try? stdinPipe.fileHandleForWriting.close()
        try? pipe.fileHandleForWriting.close()
    }

    private func augmentedPATH(base: String?) -> String {
        let basePath = base ?? ""
        let additional = InstallerHost.defaultAdditionalPathDirectories()
        var seen = Set<String>()
        var parts: [String] = []
        for dir in basePath.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        where seen.insert(dir).inserted {
            parts.append(dir)
        }
        for dir in additional where !dir.isEmpty && seen.insert(dir).inserted {
            parts.append(dir)
        }
        return parts.joined(separator: ":")
    }
}

struct SelfUpdaterBusy: Error {}
```

Note: `LineBuffer` is already private inside `LSPInstaller.swift`. Either move it to a shared location (`Alas/Sources/Helpers/LineBuffer.swift`) or duplicate it. For this plan, **move it to a shared file** in Task 1 so both models can use it.

**Step 4: Move `LineBuffer` to shared location**

- Create `Alas/Sources/Helpers/LineBuffer.swift` with the existing `LineBuffer` code, removing it from `LSPInstaller.swift`.
- Update `LSPInstaller.swift` to reference the shared `LineBuffer` (no behavior change).

**Step 5: Run test to verify it passes**

Run the same `xcodebuild -only-testing AlasTests/SelfUpdaterTests/echoSucceeds` command.

Expected: PASS.

**Step 6: Add remaining tests**

Add to `AlasTests/Updates/SelfUpdaterTests.swift`:
- `cancelRunning()` — `/bin/sleep 30`, cancel, assert `.cancelled`.
- `missingExecutableFails()` — `/bin/does-not-exist`, assert `.failed`.
- `resetClears()` — run `/bin/echo`, wait for `.finished`, call `reset()`, assert `.idle` and empty logs.
- `startWhileRunningThrows()` — run `/bin/sleep 10`, then call `start` and assert `SelfUpdaterBusy`.

Run all `SelfUpdaterTests` with:
```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/SelfUpdaterTests test -quiet 2>&1 | tail -20
```

Expected: all PASS.

**Step 7: Commit**

```bash
git add Alas/Sources/Updates/SelfUpdater.swift \
           Alas/Sources/Helpers/LineBuffer.swift \
           Alas/Sources/Code/LSP/Install/LSPInstaller.swift \
           AlasTests/Updates/SelfUpdaterTests.swift
git commit -m "feat(updates): add SelfUpdater model for inline brew upgrades"
```

---

## Task 2: Create `UpdateProgressSheet`

**Files:**
- Create: `Alas/Sources/Updates/UpdateProgressSheet.swift`
- Modify: `Alas/Sources/Updates/UpdateAvailableSheet.swift:1-107` (add `onRunUpdate`)

**Step 1: Write the sheet view**

```swift
import SwiftUI

struct UpdateProgressSheet: View {
    @Bindable var updater: SelfUpdater
    let onDone: () -> Void
    @Environment(\.theme) var theme

    private var titleText: String {
        switch updater.state {
        case .idle:
            return "Update Alas"
        case .running:
            return "Updating Alas…"
        case .finished(let exitCode):
            return exitCode == 0 ? "Update downloaded" : "Update failed"
        case .cancelled:
            return "Update cancelled"
        case .failed:
            return "Could not start update"
        }
    }

    private var commandLine: String {
        if case .running(let cl) = updater.state { return cl }
        return ""
    }

    private var isRunning: Bool {
        if case .running = updater.state { return true }
        return false
    }

    private var isSuccess: Bool {
        if case .finished(0) = updater.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(titleText)
                .font(.system(size: 16, weight: .semibold))
                .padding(.bottom, 8)

            if !commandLine.isEmpty {
                Text(commandLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color("bg-0"))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5))
                    .padding(.bottom, 12)
            }

            if isSuccess {
                Text("Quit and reopen Alas to start the new version.")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                    .padding(.bottom, 12)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(updater.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 280)
                .background(theme.color("bg-0"))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5))
                .onChange(of: updater.logLines.count) { _, newCount in
                    guard newCount > 0 else { return }
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }

            HStack(spacing: 8) {
                Spacer()
                if isRunning {
                    AlasButton(title: "Cancel", style: .subtle) {
                        updater.cancel()
                    }
                } else {
                    AlasButton(title: "Close", style: .subtle) {
                        updater.reset()
                        onDone()
                    }
                    if isSuccess {
                        AlasButton(title: "Done", style: .primary) {
                            updater.reset()
                            onDone()
                        }
                    }
                }
            }
            .padding(.top, 16)
        }
        .padding(24)
        .frame(width: 600)
        .background(theme.color("bg-1"))
        .interactiveDismissDisabled(true)
    }
}
```

**Step 2: Add `onRunUpdate` to `UpdateAvailableSheet`**

Modify `UpdateAvailableSheet`:

```swift
struct UpdateAvailableSheet: View {
    let info: ReleaseInfo
    let source: InstallSource
    let onDismiss: () -> Void
    let onRunUpdate: () -> Void
    ...

    @ViewBuilder private var actionRow: some View {
        HStack(spacing: 8) {
            switch source {
            case .homebrew:
                Text(brewCommand)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .textSelection(.enabled)
                AlasButton(title: "Copy", style: .subtle) { Clipboard.copy(brewCommand) }
                Spacer()
                AlasButton(title: "View Release", style: .subtle) { NSWorkspace.shared.open(info.htmlURL) }
                AlasButton(title: "Update", style: .primary, action: onRunUpdate)
                AlasButton(title: "Later", style: .subtle, action: onDismiss)
            case .direct:
                ...
            }
        }
        ...
    }
}
```

**Step 3: Build to catch compile errors**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build 2>&1 | tail -20
```

Expected: build succeeds.

**Step 4: Commit**

```bash
git add Alas/Sources/Updates/UpdateProgressSheet.swift \
           Alas/Sources/Updates/UpdateAvailableSheet.swift
git commit -m "feat(updates): add UpdateProgressSheet and Update button"
```

---

## Task 3: Wire `SelfUpdater` into `AppState` and `RootView`

**Files:**
- Modify: `Alas/Sources/App/AppState.swift:344-345`
- Modify: `Alas/Sources/App/RootView.swift:197-210`

**Step 1: Add `SelfUpdater` to `AppState`**

Near `let lspInstaller = LSPInstaller()` add:

```swift
    // MARK: - Self updater

    let selfUpdater = SelfUpdater()
    var presentUpdateProgress = false
```

**Step 2: Wire sheets in `RootView`**

Replace the existing `.sheet(...)` for updates with:

```swift
        .sheet(item: Binding(
            get: { state.updates.presentedUpdate },
            set: { state.updates.presentedUpdate = $0 }
        )) { info in
            UpdateAvailableSheet(
                info: info,
                source: state.updates.track == .nightly ? .direct : state.updates.source,
                onDismiss: { state.updates.presentedUpdate = nil },
                onRunUpdate: {
                    state.updates.presentedUpdate = nil
                    state.presentUpdateProgress = true
                    Task {
                        try? await state.selfUpdater.start(command: .homebrew)
                    }
                }
            )
            .environment(\.theme, state.themeStore.current)
        }
        .sheet(isPresented: $state.presentUpdateProgress) {
            UpdateProgressSheet(updater: state.selfUpdater) {
                state.presentUpdateProgress = false
            }
            .environment(\.theme, state.themeStore.current)
        }
```

Note: `state.presentUpdateProgress` must be bindable. Since `AppState` is `@Observable`, `$state.presentUpdateProgress` works directly.

**Step 3: Build and run targeted tests**

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build 2>&1 | tail -20
```

Expected: build succeeds.

**Step 4: Commit**

```bash
git add Alas/Sources/App/AppState.swift \
           Alas/Sources/App/RootView.swift
git commit -m "feat(updates): wire UpdateProgressSheet into AppState and RootView"
```

---

## Task 4: Run full tests and manual verification

**Step 1: Run full test suite**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test -quiet 2>&1 | tail -30
```

Expected: all tests pass. If the baseline suite times out again, run targeted tests:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -only-testing AlasTests/SelfUpdaterTests \
  -only-testing AlasTests/ReleaseCheckerTests \
  -only-testing AlasTests/UpdateThrottleTests test -quiet 2>&1 | tail -20
```

**Step 2: Manual verification**

Temporarily lower the current version in `project.yml`:

```yaml
info:
  properties:
    CFBundleShortVersionString: "0.8.3"
```

Run `xcodegen` and build a local copy. Launch it, then use the menu item “Check for Updates…”. The sheet should appear with an **Update** button. Click it and confirm:
- A progress sheet opens.
- `brew upgrade --cask alas` runs and prints logs.
- It exits 0 (or “Already up-to-date”).
- The app remains running.

Revert the version change afterward.

**Step 3: Commit any final fixes**

```bash
git commit -m "fix(updates): address review feedback / test failures" # if needed
```

---

## Done criteria

- [ ] `SelfUpdater` exists, tested, and can run/cancel/reset a subprocess.
- [ ] `LineBuffer` is shared between `LSPInstaller` and `SelfUpdater`.
- [ ] `UpdateProgressSheet` exists and mirrors `LSPInstallProgressSheet` style.
- [ ] `UpdateAvailableSheet` shows an **Update** button for Homebrew installs.
- [ ] Clicking **Update** dismisses the info sheet and presents the progress sheet.
- [ ] `brew upgrade --cask alas` runs inline and streams output.
- [ ] Full test suite passes (or targeted update tests pass if baseline suite is flaky).
- [ ] Manual verification confirms the flow works end-to-end.
