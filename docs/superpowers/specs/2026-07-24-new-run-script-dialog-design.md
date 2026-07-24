# New Run Script Dialog

## Problem

Creating a repo or global run script currently opens a native `NSAlert` with a
single unstyled name field. It does not match Alas's worktree-creation dialog,
and every new script unconditionally receives `# alas-on-exit: keep`. Users
must edit the generated metadata manually if the script's terminal pane should
close when the script exits.

## User Experience

Replace the alert with an Alas sheet built from `DialogContainer`,
`DialogField`, and `AlasField`.

The sheet title is **New run script**. Its subtitle communicates the scope:

- Repo: “Create a script in `.alas/scripts/` for `<repository>`.”
- Global: “Create a script available in every local worktree.”

The form contains:

- **Script name**, focused when the sheet appears. It uses the same field
  chrome and Return-to-submit behavior as the branch-name field in the new
  worktree dialog. It uses a proportional font because the value is a
  human-facing display name rather than a Git identifier.
- **When script exits**, using the same segmented-control style as
  **Open after create** in the new worktree dialog. Its choices are
  **Keep pane open** and **Close pane**. **Keep pane open** is the default,
  preserving current behavior.

The footer contains **Cancel** and **Create script**. Creation is disabled
while the trimmed name is empty. A successful creation closes the sheet and
opens the generated script in the editor, preserving existing behavior.

## Shared Segmented Control

Extract the segment rendering currently private to `NewWorktreeDialog` into a
reusable `AlasSegmentedControl`. The component owns:

- container background, border, spacing, and corner radii;
- selected and unselected text and icon styling;
- keyboard focus and its accent focus ring;
- disabled-option opacity and help text.

Callers provide the options, selected identifier, and a selection callback.
The new worktree dialog's **GG mode** and **Open after create** selectors move
to this component without changing their options or side effects. The new run
script dialog uses the same component for exit behavior. This targeted
extraction makes the visual and interaction match durable without introducing
a broader dialog-system refactor.

## Presentation And Data Flow

Introduce an identifiable pending run-script-creation request containing the
script scope and originating worktree identifier.

1. Selecting **New Repo Script…** or **New Global Script…** runs the existing
   remote-worktree preflight and records a pending request.
2. The run-script palette closes.
3. `RootView` presents `NewRunScriptDialog` from the pending request.
4. The dialog owns transient name, exit-behavior, and inline-error state.
5. On confirmation, `AppState` resolves the request's worktree and performs
   directory creation, collision detection, template writing, and executable
   permission updates.
6. `RunScriptTemplate` receives the selected `RunScriptOnExit` and emits
   `# alas-on-exit: keep` or `# alas-on-exit: close`.
7. Success clears the request, closes the sheet, and opens the repo script or
   global external file in the originating worktree's editor area.

Filesystem work and tab opening remain outside the view. Unlike the current
synchronous alert, creation failures return to the dialog so it can preserve
the user's form state.

## Validation And Failure Handling

Trim surrounding whitespace before deriving the display name and filename.
Whitespace-only names cannot be submitted. Filename slugification remains
unchanged.

If the generated filename already exists, or directory creation, writing, or
permission updates fail, keep the sheet open and show the failure inline.
Preserve the entered name and exit-behavior selection.

Repo scripts remain unavailable for remote worktrees, using the existing
preflight error before presenting the sheet. If the originating worktree no
longer exists when the user confirms, do not write a file; show an inline
message that the worktree is no longer available. Global scripts retain the
worktree identity only to choose where the created external editor tab opens.

## Testing

Focused Swift Testing coverage will verify:

- templates emit both `keep` and `close`, and each round-trips through
  `RunScriptMetadata`;
- the dialog's exit-behavior state defaults to `keep`;
- whitespace-only names are rejected and valid names are trimmed;
- repo and global requests produce the correct subtitle and destination;
- duplicate filenames return an error without discarding form state;
- successful creation preserves executable permissions and opens the correct
  repo-relative or global external editor path;
- a missing originating worktree fails without writing;
- the extracted segmented control preserves disabled-option and keyboard-focus
  behavior relied on by the worktree dialog.

Verification will run `xcodegen`, focused affected tests, the quiet macOS
build, and the repository's full macOS test command.

## Out Of Scope

- Changing filename slugification.
- Persisting a different default per scope or between creations.
- Editing metadata for existing scripts through this dialog.
- Adding additional run-script metadata such as `alas-cwd`.
- Changing run, focus, restart, or pane-exit semantics.
