# Run Script Failure Notifications Design

## Summary

Surface every non-zero Run Script completion as a dismissible, worktree-level
toast. Clicking the toast opens a sheet with the final 1 MiB of readable,
combined terminal output. The behavior applies to every script the Run Scripts
feature can currently launch, including scripts in remote worktrees, without
changing their interactive terminal context or persistence policy.

## Goals

- Notify the user when a Run Script exits non-zero, whether its `on-exit`
  setting is `keep` or `close`.
- Keep failures visible outside the Changes sidebar and independent of the
  active center tab.
- Preserve the script's terminal, stdin, working directory, environment,
  executable/shebang behavior, and exit status.
- Capture stdout and stderr as one ordered terminal transcript.
- Give the user a readable, selectable detail view with a copy action.
- Support local and remote worktrees at parity with current Run Script launch
  support.
- Bound retained failure state while leaving long-running script output live in
  the terminal as it is today.

## Non-goals

- Do not add success notifications, automatic dismissal, or clear old failures
  after a successful rerun.
- Do not add a persistent activity center, failure history, or notification
  preference.
- Do not persist failures or captured output across Alas launches.
- Do not add retry or rerun actions to the toast or detail sheet.
- Do not separate stdout and stderr or reproduce terminal colors in the sheet.
- Do not change launch/setup error alerts such as a missing script or an
  unsupported configured shell.
- Do not build a bounded streaming recorder. A transcript file may grow for the
  duration of a run and is removed after completion is collected.

## User Experience

When a Run Script exits with a non-zero code, Alas adds a toast at the
bottom-right of the originating worktree's center pane. It appears over any
active center tab in that worktree. A failure in a background worktree remains
queued and becomes visible when the user selects that worktree; it does not
produce a separate macOS notification.

Each toast shows:

- the script display name;
- **Failed with exit code N**;
- a **View output** affordance;
- a dismiss button.

Failures are newest-first and capped at three per worktree. Adding a fourth
failure drops the oldest visible failure. Each failure remains until explicitly
dismissed, even if the script later succeeds. Opening or closing its detail
sheet does not dismiss it.

Clicking the toast or **View output** opens a sheet containing:

- the script display name;
- branch;
- exit code;
- completion timestamp;
- selectable, monospaced output;
- **Copy Output** and **Done** buttons.

The sheet displays the final 1 MiB of the combined terminal transcript after
ANSI escape and terminal control processing. When truncated, it says that only
the final 1 MiB is shown. Empty output displays **No output was captured.** A
missing or unreadable transcript displays **Output could not be captured.**

`Command-C` continues to work through text selection, while **Copy Output**
copies the entire displayed output. A sheet already open keeps its failure
snapshot even if a fourth completion removes that failure from the toast cap.

Launch/setup failures continue to use the existing **Run Script Failed** alert.
Closing a pane before the recorder produces a completion status creates no
toast. Interrupting the script from inside its terminal and receiving a normal
non-zero result, such as exit code 130, does create one.

## Runtime State

Add a runtime-only `RunScriptFailure` value containing:

- a unique failure ID;
- the opaque run ID;
- script key and display name;
- originating worktree ID and branch;
- exit code and completion timestamp;
- sanitized output;
- whether the output was truncated or unavailable.

`AppState` owns failures keyed by worktree ID and the optional failure selected
for presentation. Its focused operations append and trim, dismiss by failure
ID, and select a failure for the sheet. Nothing is encoded into tab,
worktree, or app persistence. Removing a worktree drops its runtime failures.

`CenterPaneView` overlays a `RunScriptFailureToastHost` for its worktree. The
toast styling follows the existing `InlineErrorStrip` visual language, but the
Changes-specific component is not stretched into an unrelated floating layout.
The sheet is mounted above the conditional toast content so dismissing or
trimming a toast cannot implicitly tear down an open sheet.

## Run Preparation

Before launch, Alas creates an opaque run ID and registers the expected
transcript and completion paths with an in-memory monitor. Paths are derived
only from that Alas-generated ID; completion data can never direct Alas to read
an arbitrary path.

Local runs use a dedicated directory under Alas's temporary storage. Remote
runs use a private directory under `~/.alas/run-transcripts` on the configured
host. File names contain only the opaque run ID. The launch command uses a
user-only directory and `umask 077`, because a transcript may contain echoed
input or other sensitive command output. Before beginning a run it removes
only Alas-owned transcript files older than seven days; local startup performs
the same age-bounded cleanup. Removing an open old transcript does not change
the running script or its PTY, and the seven-day ceiling avoids confusing
ordinary long-lived development servers with stale files.

Alas starts the completion monitor before opening the terminal so a very short
script cannot finish before the monitor is ready:

- A local monitor waits for the run's completion sidecar without blocking the
  main actor.
- A remote monitor opens one background SSH operation through the existing
  remote execution infrastructure. It waits for the sidecar, returns the exit
  code and at most the transcript's final 1 MiB, then removes both files.

Each active remote script therefore consumes one lightweight waiting SSH
connection. This avoids reverse socket forwarding, exposing new remote control
capabilities, or installing an additional callback utility on the host.

If terminal creation fails after monitor registration, Alas cancels the monitor
and removes the allocated files. Monitor tasks are cancelled at app shutdown
and when their worktree is removed. Stale files left by an app crash or a
persisted remote shell are harmless and are removed on a later run.

## Script Recording

The generated startup suffix keeps the existing explicit `cd`, environment
assignments, executable/shebang selection, and `/bin/sh` fallback for
non-executable files. It wraps only the final invocation in the host's native
`script` utility:

- Darwin/BSD hosts use BSD `script` command/argument mode with quiet and
  immediate-flush options.
- Linux hosts use util-linux `script` command-string mode with quiet,
  immediate-flush, and child-exit-status options.

The command string and every argument remain shell-quoted by the existing
helpers. The child receives the same Run Script environment and working
directory. The recorder-provided `SCRIPT` variable is removed before executing
the user script. stdin, stdout, and stderr remain attached to a PTY, so
interactive input, output ordering, buffering, and TTY-sensitive behavior stay
available.

The observable compatibility boundary is one extra parent process and a
different PTY device. A script that explicitly inspects `PPID` or its terminal
device can observe the wrapper; ordinary build, test, and development scripts
retain their context.

If the host has no supported `script` utility, the wrapper still runs the user
script directly and reports its exit code. The toast remains available, while
the sheet reports that output could not be captured. Recorder detection must
happen before choosing recorder-specific flags so an unsupported implementation
cannot replace the user's script with a recorder usage error.

After the command returns, the wrapper atomically writes its original exit code
to the completion sidecar. It does not replace that code with recorder,
monitoring, cleanup, or notification status. For `on-exit: keep`, control then
returns to the existing interactive shell. For `on-exit: close`, the shell exits
with the preserved code and the pane follows its existing close behavior.

## Completion Data Flow

The completion monitor treats the sidecar as authoritative:

1. Wait for the registered sidecar to appear.
2. Read and validate a numeric exit code.
3. Ensure the recorder has closed the transcript before reading it; sidecar
   publication happens only after recorder completion.
4. For exit code zero, remove the files and finish without UI state.
5. For a non-zero code, read no more than the transcript's final 1 MiB.
6. Remove transcript and sidecar files.
7. Sanitize the captured bytes and append a failure to the originating
   worktree.

The remote monitor performs steps 1 through 6 in its existing outbound SSH
operation and returns a framed exit-code header followed by raw transcript
bytes. The parser splits only the first header line, so arbitrary transcript
content cannot be mistaken for control data. The local monitor produces the
same internal result type. Both paths then share sanitization and failure queue
logic.

Combined output intentionally matches what passed through the terminal rather
than preferring stderr. Input echoed by the PTY may therefore appear in the
transcript, as it did on screen.

## Output Processing

Reuse the existing `ANSIStream` parser instead of adding a second escape-code
stripper. Feed it the bounded transcript tail and join its rendered text runs,
preserving line updates, carriage-return behavior, Unicode boundaries, and
printable content while dropping styling and unsafe control sequences.

Because the 1 MiB slice can begin inside an ANSI escape or UTF-8 code point,
reuse the parser-safe tail-boundary behavior already exercised by
`ACPTerminal.snapshot`. The failure records whether the source transcript was
larger than the limit so the sheet can disclose truncation.

The on-disk transcript itself is not capped while the script runs. This is an
explicit simplification: the file is temporary, output remains live, and a
bounded custom PTY recorder would add substantial process infrastructure. Add
streaming truncation only if real scripts create unacceptable temporary disk
growth.

## Error Handling and Cleanup

- A malformed sidecar is logged, its files are removed, and no misleading
  failure is shown because the script's exit result is unknown.
- A known non-zero exit with a missing or unreadable transcript still creates a
  toast with unavailable output.
- A monitor transport failure is logged and leaves no UI result. Cleanup is
  best-effort; the next run's stale-file sweep handles leftovers.
- A monitor cancellation caused by app shutdown, worktree removal, or failed
  terminal creation creates no toast.
- A local or remote cleanup failure never changes the script's exit code or
  keeps an `on-exit: close` pane open.
- Exit code zero never clears an older failure and never produces a success
  toast.
- Multiple completions are independent; ordering uses the time Alas receives
  each validated completion.

All file operations are limited to the dedicated Alas-owned run-transcript
directory and opaque run IDs. Remote shell fragments use existing quoting
helpers and never interpolate script output into a command.

## Testing

### Recorder and Startup Command

- Executable scripts still run directly under their shebang; non-executable
  scripts still use `/bin/sh`.
- cwd, Run Script environment values, arbitrary quoted paths, arguments, stdin,
  and TTY-backed stdout/stderr are preserved.
- The injected `SCRIPT` value is absent from the user script.
- Combined stdout/stderr ordering is recorded and still displayed live.
- Darwin/BSD and Linux/util-linux command forms preserve exit codes.
- Missing or unsupported recorder fallback runs the actual script and publishes
  its exit code without captured output.
- `keep` returns to the shell and `close` exits the shell with the original
  status.

### Completion Monitoring

- The monitor is registered before terminal launch and cancelled on launch
  failure.
- Local and remote framed results parse to the same completion value.
- Success removes temporary files without creating UI state.
- Failure reads only the final 1 MiB and removes temporary files.
- Missing transcripts retain the exit result with unavailable output.
- Malformed sidecars, transport failures, cancellation, and unknown run IDs do
  not create false failures.
- Remote command construction quotes paths, waits for atomic completion, limits
  returned bytes, and cleans both files.
- Transcript files use user-only permissions, and stale cleanup touches only
  Alas-owned run-transcript files older than seven days.

### Output Processing

- ANSI styling, OSC strings, BEL, and other control sequences are removed.
- Carriage-return progress output resolves to readable text.
- A tail beginning inside an escape or multibyte UTF-8 sequence resynchronizes
  without leaking control fragments or replacement characters.
- Empty, unavailable, and truncated presentation states are distinct.

### Failure State and UI

- A non-zero completion creates a failure for its originating worktree for both
  `keep` and `close` scripts.
- Failures remain after a later success and until explicitly dismissed.
- Each worktree retains only its three newest failures.
- Independent dismissal removes only the selected failure.
- A failure in a background worktree appears when that worktree is selected.
- Clicking a toast selects its sheet; closing the sheet leaves the toast.
- Copy Output copies the complete displayed output.
- The sheet remains stable if its toast is trimmed from the capped queue.
- Removing a worktree clears its monitor tasks and failures.

## Verification

Run focused Run Script, remote command, ANSI parser, AppState, and presentation
tests first. Then run the repository-required verification serially:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
