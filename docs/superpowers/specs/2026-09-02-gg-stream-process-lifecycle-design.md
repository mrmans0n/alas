# GG streaming process lifecycle

## Problem

`gg sync --jsonl` may emit its terminal summary while the process or one of its descendants remains alive. The bounded post-summary drain must eventually cancel that process tree without releasing `GGMutationCoordinator` early. The current implementation cannot reliably handle descendants that detach from the root process group, and watchdog termination no longer gives commands a chance to remove locks or temporary files.

## Design

Add a private `GGStreamingProcessTree` controller beside `ProcessGGCommandRunner`. Each streaming command owns one controller for its full lifetime.

After `Process.run()`, the controller attempts `setpgid`, captures the initial descendants, observes forks, and periodically refreshes an accumulated set of `(pid, process start time)` identities. It reuses the existing libproc identity helpers from `ACPTerminal`; no second PID parser is added.

Termination is serialized so cancellation, the watchdog, and the process termination handler cannot run competing cleanup sequences. Cleanup sends `SIGTERM` to the live root process group, root PID, and identity-validated descendants. It allows a two-second grace period, then sends `SIGKILL` to any remaining live root/group and validated descendants. The controller never signals a process group after the root has exited.

The stream does not finish until an active cleanup sequence completes. Normal zero or nonzero exits keep their existing stdout/stderr drain and error mapping behavior.

## Scope

This change stays within gg streaming. It reuses `ACPTerminal`'s process identity queries but does not migrate the LSP, JSON-RPC, or terminal transports to a new shared owner in this pull request.

## Tests

- A streaming shell whose descendant creates a new session and ignores `SIGTERM` must leave no live descendant after cancellation returns.
- A watchdog timeout must send `SIGTERM` first, allowing a trap to record graceful shutdown before exit.
- Existing `GGCommandRunningStreamingTests` and `GGServiceActionsTests` must remain green.
- Run `xcodegen`, SwiftFormat lint, and a full macOS build before each push.
