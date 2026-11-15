# Held agent calls for VMs: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `computer_*` and `vm_run` calls to a VM the user drives wait up to
50 s for hand back, as simulator calls do.

**Architecture:** The simulator's hold moves into AlasCore `HeldCalls`.
`DeviceAgentControl` uses it unchanged in behaviour. The VM gate's decision
becomes `VMTakeOvers.held(action:driver:hold:)`, a small async function with
injected closures, so it is unit tested; `AppState` wires it to a
`vmHolds: HeldCalls` and releases on hand back and VM stop.

**Tech Stack:** Swift 6, Swift Testing, Rust (descriptions only).

**Spec:** `docs/plans/2026-11-14-devices-vm-held-calls-design.md`

## Global Constraints

- Hold limit 50 s (`.seconds(50)`); injected `sleep` in tests.
- Arrival order kept, and `onRelease` hooks run synchronously in that order at `releaseAll`.
- A cancel (`ComputerUseCommand.Action.cancel`) never holds; `vm_status` never holds.
- Timeout keeps today's `VMAutoStartMessages.userDriving`; a cancelled hold returns `ComputerUseCoordinator.Messages.cancelled` (`computer_cancelled: …`) — check the exact name of the `cancelled` constant's enclosing type.
- AlasCore must not import AppKit/SwiftUI; Swift Testing; no fixed sleeps in tests; `swiftformat --lint` clean.

## Review Focus

- Simulator held calls must keep their order and input turns (existing `DeviceAgentControlTests`: `heldCallsRunInArrivalOrder`, `aCallMadeWhileTheUserDrivesRunsAfterHandBack`, and the rest).
- A released VM call must re-check the gate: the user may take over again before it runs (Task 2 test: release, then still driving → hold again).
- A VM that stops while calls wait must release them, or they'd sit until the 50 s limit (Task 3 wiring; covered by `HeldCalls.releaseAll` semantics).
- Cancelling a waiting call must not release the others (Task 1 test).

---

### Task 1: `HeldCalls` and the simulator on it

**Files:**
- Create: `Packages/AlasCore/Sources/AlasFeatures/Devices/HeldCalls.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HeldCallsTests.swift` (new type)
- Modify: `Alas/Sources/Devices/DeviceAgentControl.swift`

**Interfaces:**

```swift
@MainActor
public final class HeldCalls {
    public enum Outcome: Equatable, Sendable { case released, timedOut, cancelled }
    public init(limit: Duration = .seconds(50), sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) })
    public func hold(_ key: String, sessionID: String, onRelease: @escaping @MainActor () -> Void = {}) async -> Outcome
    public func releaseAll(_ key: String)
    public func waiting(_ key: String) -> [String]
}
```

- [ ] **Step 1: Failing tests** (`HeldCallsTests`, `@MainActor`, a `sleep` that suspends until cancelled for the limit, and one that returns at once for the timeout test):
  - `releasesInArrivalOrderRunningOnReleaseFirst`: three holds on "vm" from sessions a, b, c with `onRelease` appending to a log; after `eventually { waiting("vm") == ["a","b","c"] }`, `releaseAll("vm")`; the log is `["a","b","c"]` and all three outcomes are `.released`.
  - `aHoldTimesOut`: with the immediate sleep, `hold` returns `.timedOut` and `waiting` is empty.
  - `aCancelledHoldLeavesTheQueue`: hold a and b; cancel a's task → `.cancelled`; `waiting == ["b"]`; `releaseAll` → b `.released`.
  - keys are independent: `releaseAll("x")` doesn't release "y".
- [ ] **Step 2: Run** `swift test --package-path Packages/AlasCore --filter HeldCallsTests` → compile error.
- [ ] **Step 3: Implement** by moving `DeviceAgentControl`'s `HeldCall`, `holdWhileTakenOver` and `release` into `HeldCalls` (continuation per call, a timer task per call that releases as `.timedOut`, `withTaskCancellationHandler` releasing as `.cancelled`, `releaseAll` resuming in order after running `onRelease`).
- [ ] **Step 4: Move the simulator onto it.** `DeviceAgentControl` gets `private let holds: HeldCalls` built from `holdLimit` and `sleep`; `holdWhileTakenOver(udid, sessionID:, isInput:)` becomes:

```swift
guard takenOver.contains(udid) else { return .go(inputTurn: nil) }
guard !Task.isCancelled else { return .cancelled }
var turn: UUID?
switch await holds.hold(udid, sessionID: sessionID, onRelease: { [weak self] in
    if isInput { turn = self?.takeInputTurn(udid) }
}) {
case .released: return .go(inputTurn: turn)
case .timedOut: return .timedOut
case .cancelled: return .cancelled
}
```

  `handBack` calls `holds.releaseAll(udid)` instead of its loop; `waitingSessions(udid:)` returns `holds.waiting(udid)`. Delete the moved code.
- [ ] **Step 5: Run** AlasCore filter and `-only-testing AlasTests/DeviceAgentControlTests` → all pass unchanged.
- [ ] **Step 6: Commit** "refactor(devices): hold agent calls through one shared type".

### Task 2: The VM gate holds

**Files:**
- Modify: `Alas/Sources/VM/VMComputerUseRoute.swift` (`VMTakeOvers`)
- Test: `AlasTests/VMComputerUseRouteTests.swift`

**Interfaces:**

```swift
/// The gate's verdict for an agent call, holding it while the user drives: nil to go on, else the
/// error. `hold` waits for hand back (`HeldCalls.hold`), `driver` reads the VM's driver now.
static func held(
    action: ComputerUseCommand.Action?, driver: () -> VMDriver,
    hold: () async -> HeldCalls.Outcome
) async -> String?
```

- [ ] **Step 1: Failing tests:** driver `.user` then `.idle` after one hold returning `.released` → nil, hold called once; driver stays `.user` and hold returns `.released` twice, then `.timedOut` → `VMAutoStartMessages.userDriving` after three holds; `.cancelled` → the cancelled message; `action: .cancel` with `.user` → nil, hold never called; `.idle` → nil, hold never called.
- [ ] **Step 2: Run** `-only-testing AlasTests/VMComputerUseRouteTests` → compile error.
- [ ] **Step 3: Implement:**

```swift
static func held(action:, driver:, hold:) async -> String? {
    guard action != .cancel else { return nil }
    while VMDriver.decision(for: driver()) == .userDriving {
        switch await hold() {
        case .released: continue
        case .timedOut: return VMAutoStartMessages.userDriving
        case .cancelled: return <cancelled message>
        }
    }
    return nil
}
```

- [ ] **Step 4: Run** → PASS. **Commit** "feat(vm): hold agent calls while the user drives a VM" (with Task 3, if it builds only together).

### Task 3: Wire it in `AppState`, status text, tools

**Files:** `Alas/Sources/App/AppState.swift` (`vmHolds`), `Alas/Sources/App/AppState+ComputerUse.swift`, `Alas/Sources/VM/VMTabScreen.swift`, `Alas/Sources/VM/VirtualMachineTabView.swift`, `Alas/Sources/Devices/DevicesTabView.swift`, `Alas/Sources/App/DesignCaptureVM.swift`, `Alas/Sources/App/DesignCaptureDevices.swift`, `AlasTests/VMTabScreenTests.swift`, `AlasCLI/crates/alas/src/mcp.rs`, `ACPMCPPromptPreamble.swift`, docs.

- [ ] **Step 1:** `AppState`: `@ObservationIgnored let vmHolds = HeldCalls()`; observation for the waiting list: make `HeldCalls` `@Observable` (its `held` dictionary observed) so the status redraws — add `import Observation` and `@Observable` in Task 1 if not already.
- [ ] **Step 2:** In the computer path, before the first `vmCallRefusal` (after `await vmHandingBack[recordID]?.value`), add:

```swift
if let refusal = await VMTakeOvers.held(
    action: command.action, driver: { [weak self] in self?.vmDriver(recordID: recordID) ?? .idle },
    hold: { [weak self] in await self?.vmHolds.hold(recordID, sessionID: sessionID) ?? .cancelled }
) { return .error(refusal) }
// A hand back's resume and turnEnded go out before the released call.
await vmHandingBack[recordID]?.value
```

  and the same before `vm_run`'s `vmCallRefusal(action: nil, …)`. The existing refusals stay as the later checks.
- [ ] **Step 3:** `handBackVM`: after the resume bookkeeping, `vmHolds.releaseAll(recordID)`. The VM-stopped path (the function containing `vmTakeOvers.vmStopped(recordID)`): `vmHolds.releaseAll(recordID)`.
- [ ] **Step 4: Status.** `VMDriverStatus.make(driver:agentName:now:waiting: [String] = [])`: for `.user`, details `["\(first) is waiting"]` (`+ " +\(n - 1) more"` when several, names via the caller-supplied names) else `["agent calls wait for you to hand back"]`. Callers pass `state.vmHolds.waiting(recordID).map(agentName)` — `VMDriverStatus.make` takes already-resolved names: `waiting: [String]`. Update `VMTabScreenTests` with one parameterized case for 0, 1 and 2 waiting.
- [ ] **Step 5: Text.** In `mcp.rs`, the computer/vm descriptions that mention `computer_user_active` say: "While the user drives a VM, a call waits up to 50 seconds for them to hand it back; `computer_user_active` means it is still theirs: try again later." (find them with `grep -n computer_user_active AlasCLI/crates/alas/src/mcp.rs`); the preamble's VM sentence likewise. `docs/devices.md` VMs section: "While you drive a VM, an agent's call to it waits up to 50 seconds for you to hand it back." Device panel design: replace "VM takeover still refuses calls; it never paused the agent's turn either." with "VM calls are held the same way (`2026-11-14-devices-vm-held-calls-design.md`)."
- [ ] **Step 6: Run** cargo, `VMComputerUseRouteTests`, `VMTabScreenTests`, `DeviceAgentControlTests`, `ACPMCPPromptPreambleTests`, build-for-testing, lint. **Commit** "feat(vm): hold agent calls while the user drives a VM" and "docs(devices): describe held VM calls".
- [ ] **Step 7: Manual pass** (the user): take over a VM, have an agent click, hand back within 50 s; the status names the waiting agent.
