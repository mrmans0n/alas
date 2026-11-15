# Devices: held agent calls for VMs

## Goal

An agent's `computer_*` or `vm_run` call to a VM the user has taken over
waits for the user to hand it back, as simulator calls do, instead of
failing at once. Item E of the Devices follow-ups (A logs, B clipboard and
text, C small controls, D settle-and-diff, E held calls for VMs).

## What exists

- Simulators: `DeviceAgentControl.holdWhileTakenOver` keeps a call while
  the user drives, up to 50 s (`holdLimit`, with an injected `sleep`).
  Hand back resumes held calls in arrival order and gives input calls their
  input turn at that moment, so they run in arrival order even though a
  released call still lists devices first. A cancelled caller leaves the
  queue; a timeout fails with `device_user_active`. The stage pill says
  "<agent> is waiting" from `waitingSessions(udid:)`.
- VMs (`AppState+ComputerUse.swift`):
  - Take over (`takeOverVM`) sends the guest `stop` for the sessions that
    drive it and cancels `vm_run`s; hand back (`handBackVM`) queues `resume`
    for them. Calls in flight during a take over return
    `computer_user_active` (`VMTakeOvers.afterCall`).
  - A new call while taken over is refused at once by
    `VMTakeOvers.refusal` with `VMAutoStartMessages.userDriving`
    (`computer_user_active: …`). The VM tab's status says "You're driving ·
    agent calls are on hold", which isn't what happens.
  - `vm_status` answers at once and reports `user_driving`.
  - A cancel (`ComputerUseCommand.Action.cancel`) always passes the gate.

## Decisions

- `computer_*` and `vm_run` calls wait up to 50 s for hand back, then run
  in arrival order; `vm_status` and cancels answer at once.
- One hold mechanism for simulators and VMs.

## 1. `HeldCalls` (AlasCore)

`@MainActor public final class HeldCalls` in `AlasFeatures/Devices`, the
simulator's hold logic moved out of `DeviceAgentControl`:

- `init(limit: Duration = .seconds(50), sleep: @escaping @MainActor (Duration) async -> Void)`.
- `hold(_ key: String, sessionID: String, onRelease: @escaping @MainActor () -> Void = {}) async -> Outcome`
  with `Outcome` `released`, `timedOut`, `cancelled`. Suspends until
  `releaseAll(key)`, the limit, or the caller's task being cancelled.
- `releaseAll(_ key: String)` resumes the held calls of `key` in arrival
  order, running each one's `onRelease` synchronously first, so whatever
  must be ordered (the simulator's input turns) is taken in arrival order.
- `waiting(_ key: String) -> [String]`: the session ids, in arrival order.

`DeviceAgentControl` keeps its behaviour: `holdWhileTakenOver` becomes a
call to `HeldCalls.hold` whose `onRelease` takes the input turn for an input
call, `handBack` calls `releaseAll`, `waitingSessions` reads `waiting`. Its
existing tests pin that nothing changed.

## 2. VMs

- `AppState` gets `vmHolds: HeldCalls` (keyed by the VM's registry id).
- Where `vmCallRefusal` returns the user-driving refusal for a
  `computer_*` call or `vm_run`, the call holds instead:
  - `released`: check the gate again (the user may have taken it over
    again, or setup started) and go on as a fresh call;
  - `timedOut`: today's `computer_user_active` error;
  - `cancelled`: the error a cancelled VM call gets today.
- `handBackVM` calls `vmHolds.releaseAll(recordID)` after queuing the
  guests' `resume`s. A VM that stops (`vmStopped`) also releases its held
  calls: the take over is over, and the calls go on as they would for a
  stopped VM (auto-start or its error).
- While calls wait, `vmLastAgentCall` isn't touched, so the driver stays
  `.user`.

## 3. Status

`VMDriverStatus.make(driver:agentName:now:waiting:)` takes the waiting
session ids: with the user driving, the details read "<agent> is waiting"
for the first one (and "+N more" when several), else "agent calls wait for
you to hand back". The VM tab and the Devices tab's VM card pass
`state.vmHolds.waiting(recordID)`.

## Tools and docs

- `computer_*` and `vm_run` descriptions: the existing
  `computer_user_active` sentence becomes "While the user drives a VM, a
  call waits up to 50 seconds for them to hand it back;
  `computer_user_active` means it is still theirs: try again later." The
  preamble's VM sentence says the same.
- `docs/devices.md` "VMs" section: calls wait while you drive.
- Remove "VM takeover still refuses calls" from the device panel design's
  follow-ups.

## Testing

- AlasCore `HeldCallsTests`: release in arrival order with `onRelease`
  order; timeout; cancel leaves the queue and the next still releases;
  `waiting`.
- App: `DeviceAgentControlTests` unchanged and passing (behaviour kept).
  VM: a test in the VM computer-use suite that a call during a take over
  waits, runs after hand back, and that one past the limit fails with
  `computer_user_active` (fake guest client and injected sleep, as that
  suite already uses). `VMDriverStatus` waiting text in its existing tests.
- Rust: description text only; tool-list tests unaffected.
- A manual pass: take over a VM, ask an agent to click something, hand back
  within 50 s.
