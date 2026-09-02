# GG Streaming Process Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make streaming gg cancellation and watchdog timeouts finish only after graceful, identity-safe process-tree cleanup.

**Architecture:** A gg-local `GGStreamingProcessTree` owns process-group setup, descendant snapshots, fork observation, periodic refresh, and serialized TERM-to-KILL cleanup. `ProcessGGCommandRunner.streamProcess` delegates process lifecycle to it and waits for active cleanup before finishing the stream.

**Tech Stack:** Swift 5.9+, Foundation `Process`, Darwin signals/libproc, Swift Testing

**Spec:** `docs/superpowers/specs/2026-09-02-gg-stream-process-lifecycle-design.md`

## Global Constraints

- Keep the controller private to gg streaming; do not migrate LSP or JSON-RPC transports.
- Reuse `ACPTerminal.DescendantKey`, `collectChildDescendants(of:)`, and `currentlyMatching(_:)`; do not add another PID parser.
- Never signal a process group after the root has exited.
- Send `SIGTERM`, allow at most two seconds, then send `SIGKILL` only to still-valid targets.
- Stream completion must wait for an active cleanup sequence.

---

### Task 1: Graceful watchdog cleanup

**Files:**
- Create: `Alas/Sources/Integrations/GG/GGStreamingProcessTree.swift`
- Modify: `Alas/Sources/Integrations/GG/GGService.swift:91-208`
- Test: `AlasTests/Integrations/GGCommandRunningStreamingTests.swift:61-72`

**Interfaces:**
- Produces: `GGStreamingProcessTree.init(process:)`, `start()`, `rootDidExit()`, `terminateAndWait(graceNanoseconds:)`, and `waitForActiveTermination()`.
- Consumes: `ACPTerminal.DescendantKey`, `collectChildDescendants(of:)`, and `currentlyMatching(_:)`.

- [ ] **Step 1: Add a failing graceful-watchdog test**

Add a test that launches a shell with a TERM trap, uses a short watchdog timeout, consumes the stream to its timeout error, and asserts the trap wrote a marker file:

```swift
@Test func watchdogAllowsGracefulTerminationBeforeKilling() async throws {
    let marker = FileManager.default.temporaryDirectory
        .appendingPathComponent("alas-gg-term-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    var env = ProcessInfo.processInfo.environment
    env["TERM_MARKER"] = marker.path
    let stream = ProcessGGCommandRunner.streamProcess(
        executable: "/bin/sh",
        args: ["-c", "trap 'echo term > \"$TERM_MARKER\"; exit 0' TERM; while :; do sleep 0.05; done"],
        cwd: nil,
        env: env,
        timeout: 0.1
    )

    await #expect(throws: ProcessError.self) {
        _ = try await collectWithTimeout(stream)
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /tmp/alas-blink182-dd \
  -only-testing:AlasTests/GGCommandRunningStreamingTests/watchdogAllowsGracefulTerminationBeforeKilling \
  test -quiet
```

Expected: FAIL because the current helper sends `SIGKILL` before the TERM trap can run.

- [ ] **Step 3: Add the minimal serialized lifecycle controller**

Create `GGStreamingProcessTree` with an `NSCondition` protecting `rootHasExited`, `terminationInProgress`, and `terminationComplete`. `terminateAndWait` must:

```swift
func terminateAndWait(graceNanoseconds: UInt64 = 2_000_000_000) {
    // One caller owns cleanup; concurrent callers wait for it.
    // While the root is current, send SIGTERM to group, validated descendants, and root.
    // Wait until root and validated descendants exit or the deadline passes.
    // Send SIGKILL to remaining current targets, then wait for the root.
    // Mark cleanup complete and wake termination-handler waiters.
}
```

`rootDidExit()` records the transition before any later group signal can run. `waitForActiveTermination()` returns immediately for natural exits and blocks only while cleanup owns the process tree.

- [ ] **Step 4: Wire the controller into streaming**

In `streamProcess`:

```swift
let processTree = GGStreamingProcessTree(process: process)
```

Call `processTree.start()` immediately after `process.run()`. Call `rootDidExit()` at the start of the termination handler. Before mapping the exit status, call `waitForActiveTermination()`. Replace watchdog and `onTermination` force-kills with `terminateAndWait()` and remove `forceTerminateGGStreamingProcessTree`.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /tmp/alas-blink182-dd \
  -only-testing:AlasTests/GGCommandRunningStreamingTests test -quiet
```

Expected: all `GGCommandRunningStreamingTests` pass, including the TERM marker test.

- [ ] **Step 6: Commit the graceful lifecycle**

```bash
git add Alas/Sources/Integrations/GG/GGStreamingProcessTree.swift \
  Alas/Sources/Integrations/GG/GGService.swift \
  AlasTests/Integrations/GGCommandRunningStreamingTests.swift
git commit -m "fix(gg): restore graceful stream termination"
```

### Task 2: Track detached descendants

**Files:**
- Modify: `Alas/Sources/Integrations/GG/GGStreamingProcessTree.swift`
- Test: `AlasTests/Integrations/GGCommandRunningStreamingTests.swift:74-119`

**Interfaces:**
- Consumes: Task 1's `GGStreamingProcessTree` lifecycle methods.
- Produces: accumulated identity-validated descendants plus fork-observer and polling cleanup owned by the controller.

- [ ] **Step 1: Strengthen the cancellation test for a detached child**

Change the child command to `/usr/bin/python3`, delay briefly so the root fork observer can snapshot it, call `os.setsid()`, ignore TERM, write its PID, and sleep. Pass the Python source through the environment so shell quoting cannot change it:

```swift
env["PYTHON_CODE"] = #"import os,signal,time; time.sleep(0.2); os.setsid(); signal.signal(signal.SIGTERM, signal.SIG_IGN); f=open(os.environ['CHILD_PID_FILE'],'w'); f.write(str(os.getpid())); f.flush(); time.sleep(30)"#
let script = #"/usr/bin/python3 -c "$PYTHON_CODE" & echo $$ > "$PID_FILE"; wait"#
```

Keep the observable contract: after `consumer.cancel()` returns, both root and detached child must stop.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /tmp/alas-blink182-dd \
  -only-testing:AlasTests/GGCommandRunningStreamingTests/cancelingStreamKillsProcessThatIgnoresTermination \
  test -quiet
```

Expected: FAIL because the child leaves the root group and becomes unfindable after root exit.

- [ ] **Step 3: Track identities for the process lifetime**

Extend `GGStreamingProcessTree.start()` to install a `.fork` `DispatchSourceProcess` for the root, capture the initial descendants, observe captured descendants, and start a one-second detached refresh task. Every refresh unions live descendants with cached entries that still pass `ACPTerminal.currentlyMatching`.

Cancellation and `rootDidExit()` cancel the refresh task and all fork sources. Termination snapshots the cached identities before signaling and only signals cached PIDs that still match their captured start times.

- [ ] **Step 4: Run streaming and sync-action tests**

Run:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /tmp/alas-blink182-dd \
  -only-testing:AlasTests/GGCommandRunningStreamingTests \
  -only-testing:AlasTests/GGServiceActionsTests test -quiet
```

Expected: both suites pass.

- [ ] **Step 5: Commit detached-descendant tracking**

```bash
git add Alas/Sources/Integrations/GG/GGStreamingProcessTree.swift \
  AlasTests/Integrations/GGCommandRunningStreamingTests.swift
git commit -m "fix(gg): track streaming descendants"
```

### Task 3: Verify and resume shepherding

**Files:**
- Modify only files required by formatting or project generation; no unrelated cleanup.

**Interfaces:**
- Consumes: completed Tasks 1 and 2.
- Produces: a pushed PR head with local verification evidence.

- [ ] **Step 1: Regenerate and lint**

```bash
xcodegen
swiftformat Alas AlasTests --lint --reporter github-actions-log
```

Expected: project generation succeeds and SwiftFormat reports zero files requiring changes.

- [ ] **Step 2: Build the macOS app**

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -derivedDataPath /tmp/alas-blink182-dd build -quiet
```

Expected: exit code 0.

- [ ] **Step 3: Check the final diff and push**

```bash
git diff --check
git status --short
git push
```

- [ ] **Step 4: Reply to and resolve the two current Codex threads**

Reply with the pushed commit IDs and test evidence, then resolve threads `PRRT_kwDOSQKdXs6eQvQc` and `PRRT_kwDOSQKdXs6eQvQj`.

- [ ] **Step 5: Poll until both completion signals arrive**

Watch the latest CI run with `gh run watch`. Poll PR reactions, review threads, and the Codex summary until CI succeeds and `chatgpt-codex-connector` posts `+1`. Address any new narrow finding through the same test-first repair loop; stop for another architectural conflict.
