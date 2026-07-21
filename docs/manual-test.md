# Alas Manual Test Script

## Repository and Worktree Management

1. Start Alas with `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" cargo run` if Zig 0.15 is not already on `PATH`; otherwise `cargo run` is sufficient.
2. Add an existing Git repository.
3. Confirm the main worktree and linked worktrees appear in the left navigator.
4. Create a worktree from the row overflow menu.
5. Archive and unarchive it from the row overflow menu.
6. Remove a linked worktree and confirm the destructive prompt.
7. Prune stale worktrees and confirm the destructive prompt.
8. Open command settings and configure at least two commands.

## UI Overhaul

1. On macOS, start Alas with `cargo run` and confirm the normal titlebar is visually reclaimed: app content is flush with the window and traffic-light buttons sit approximately 20px from the top.
2. Confirm the top-left safe area is reserved in the left sidebar: no repository row, text, or button sits under the traffic-light buttons.
3. Drag the window from the top-left safe/chrome area and confirm the window moves.
4. Try dragging from terminal content, repository rows, worktree rows, and right-sidebar rows; confirm those areas do not drag the window.
5. Confirm Linux still shows conventional window chrome if tested on Linux.
6. Confirm the app reads as three columns: repository/worktree tree, flush terminal pane, grouped files/Git tree.
7. Expand and collapse repository nodes in the left sidebar.
8. Right-click a repository row and a worktree row; confirm contextual popover menus show the expected actions.
9. Click each overflow button and confirm it opens the same action set as right-click.
10. Use the bottom icon-only add repository button; confirm its hover tooltip says “Add repository.”
11. Select a worktree and confirm the center terminal starts without a persistent `Worktree:` label or workspace card border.
12. Hover the top edge of the terminal; confirm terminal tabs and the new-tab control appear.
13. Open a second terminal tab and confirm the tab overlay remains available for switching.
14. Confirm terminal scroll, mouse, keyboard, paste, resize, and alternate-screen behavior still match the Terminal Emulator Behavior section.
15. Confirm the right sidebar shows a single grouped tree with Changed and Files sections, not Files/Changes tabs.
16. Expand and collapse directories in the right Files section.
17. Create or modify a file and confirm the Changed section updates independently of the Files section.
18. Confirm the old full-width bottom status bar is gone.

## macOS Window Material

1. On macOS, set a colorful desktop wallpaper or place a colorful window (e.g.
   Finder showing a vivid background) where Alas's sidebar will sit.
2. Start Alas with `cargo run`.
3. Confirm the left sidebar is visibly translucent: the wallpaper / window
   behind Alas shows through as a soft blurred wash.
4. Confirm the titlebar drag region (the strip above the sidebar/terminal
   reserved by `mac_titlebar_safe_area_height_px`) also shows the blurred
   material around the traffic-light buttons.
5. Confirm the terminal canvas remains fully opaque — text legibility is
   unchanged from the prior build.
6. Confirm the floating tab overlay pill (when terminal tabs are visible)
   remains fully opaque.
7. Drag a colorful window behind Alas across the desktop and verify the blur
   under the sidebar updates in real time.
8. On Linux, repeat steps (2)–(7) and confirm the sidebar and root are fully
   opaque (no behavior change vs. the prior build).

## Desktop Packaging and Lifecycle

### macOS `.app`

1. On macOS, build the app bundle with `cargo xtask dist macos`.
2. Confirm `dist/macos/Alas.app` exists.
3. Launch `Alas.app` by double-clicking it in Finder.
4. Add/open a repository and start a terminal session.
5. Press `Cmd+Q`; confirm the app exits.
6. Relaunch, then close the window with the traffic-light close button; confirm the process exits.
7. Confirm `dist/macos/Alas-<version>-<arch>.zip` exists.

### Linux AppImage

1. On Linux, ensure `appimagetool` is on `PATH`.
2. Build with `cargo xtask dist linux-appimage`.
3. Confirm `dist/linux/appimage/*.AppImage` exists and is executable.
4. Run the AppImage.
5. Add/open a repository and start a terminal session.
6. Press `Ctrl+Q`; confirm the app exits.
7. Relaunch and close the window; confirm the process exits.

### Linux Debian package

1. On Linux, build with `cargo xtask dist linux-deb`.
2. Confirm `dist/linux/deb/*.deb` exists.
3. Install with `sudo apt install ./dist/linux/deb/<package>.deb`.
4. Launch `alas` from a terminal and, if available, from the desktop app launcher.
5. Add/open a repository and start a terminal session.
6. Confirm Quit shortcut and window close exit the app.
7. Remove the package after testing if desired.

## Terminal Tabs

1. Select a worktree.
2. Confirm the default terminal tab starts in that worktree.
3. Create a second terminal tab from the configured-command picker.
4. Switch tabs and confirm output/process state is preserved.
5. Switch worktrees and return; confirm tabs still exist for the original worktree.
6. For a short-lived or failed command tab, confirm the final screen remains visible with exited/failed status plus Restart or Retry controls.
7. For startup failure, temporarily make a disposable worktree path unavailable; confirm the failed tab shows command, cwd, cause, Retry, and Edit Command, then restore the path and retry.

## Harness Completion Notification Click-Through

1. On macOS, start Alas with `cargo run` or from `Alas.app`.
2. Allow notification permissions for Alas when macOS prompts. If the prompt does not appear, enable Alas in System Settings → Notifications.
3. Select a worktree and open a Claude Code or Codex terminal tab with Alas hook integration enabled.
4. Trigger a successful hook-backed completion that emits `terminal_tab_id` or `alas_terminal_tab_id`.
5. Switch to another Alas worktree/tab or another app.
6. Click the completion notification and confirm Alas comes to the foreground, selects the originating worktree, selects the originating terminal tab, and focuses the terminal pane.
7. Trigger another hook-backed completion, close the originating tab, then click the old notification. Confirm Alas focuses without a visible error or crash.
8. Trigger a heuristic/unsupported harness detection without a validated hook payload. Confirm it does not route to a tab through notification click-through.

## Harness Waiting Notifications

1. Enable finish and awaiting harness notifications in Terminal settings.
2. Install the Claude Code hook from Terminal settings, then restart Claude Code or reload hooks as required by Claude Code.
3. Trigger a Claude Code permission prompt or leave the prompt input idle until Claude emits a `Notification` hook. Confirm Alas shows a clickable "needs input" macOS notification and clicking it focuses the originating worktree/session.
4. Let Claude Code finish a response. Confirm the existing completion notification still appears and still clicks through correctly.
5. For Codex or Aider, wire the wrapper from Terminal settings only when the local integration can reliably detect waiting. Invoke the wrapper with `--kind awaiting` for waiting states and without `--kind` for completion. If the upstream tool cannot emit reliable waiting hooks, do not synthesize waiting from terminal text scraping.
6. OpenCode is currently supported through ACP in Alas, not as a terminal `HarnessKind`; ACP waiting-state notifications are deferred to separate ACP notification work.

## Terminal Emulator Behavior

1. Shell basics: type, edit prompt, arrows/history, backspace/delete, Tab, Escape, and Ctrl-C.
2. ANSI colors: run a 16/256/truecolor color script and confirm no raw escape sequences.
3. Scrollback: run `yes | head -1000`, then scroll with trackpad/mouse.
4. Alternate screen: run `less README.md` and quit.
5. Editor: run `vim` or `nvim`, type text, then quit without saving.
6. Live TUI: run `top` or `htop`, then quit.
7. Resize: run `stty size`, resize the Alas window, then run `stty size` again and confirm rows/columns changed.
8. AI agent: run `claude` or `codex` if installed; confirm long output survives tab/worktree switches.
9. Known limitation: Option/Alt behavior may depend on terminal/input settings; verify common Meta movement only if configured for the test environment.

### Ghostty-first Canvas Renderer

1. Claude Code: run `claude`; prompt area, status bars, input field, and backgrounds render without chopped bars or mismatched trailing backgrounds.
2. Vim/nvim: open editor, enter insert mode, type, move cursor, quit without saving.
3. Less alternate screen: run `less README.md`, scroll, quit, and confirm shell screen returns.
4. htop/top: run a live TUI, verify repaint stability, quit.
5. Colors: run 16/256/truecolor scripts and verify backgrounds extend through padded regions.
6. Wide text: print CJK text, emoji, and box drawing; verify columns remain aligned.
7. Mouse: verify shell scrollback still works; in mouse-aware TUIs, verify clicks/wheel are sent when supported.
8. Resize: run `stty size`, resize the window, run `stty size` again, confirm cell size changed correctly.

## Grouped Project Inspector

1. Select a worktree and confirm the right sidebar shows a single grouped tree, not separate Files and Changes tabs.
2. Confirm the Changed section shows modified/untracked files with status badges.
3. Confirm the Files section shows worktree files and supports directory expand/collapse.
4. Confirm file loading errors remain scoped to the Files section and do not break terminal input.
5. Confirm Git status loading errors remain scoped to the Changed section and do not break terminal input.
6. Create an ignored root directory such as `.build/` and confirm it appears in the Files section with a dimmed ghost-rail row and an `ignored` pill.
7. Expand the ignored root directory and confirm only the first level appears at first; deeper directories load only when expanded.
8. Add a path to `.git/info/exclude`, create the matching file or folder, and confirm it appears with an `excluded` pill.
9. Create a normal untracked file and confirm it still uses the existing `A` badge instead of the ignored/excluded affordance.

## ACP Agent Chat

1. Ensure an ACP provider is installed, for example `opencode acp` or another provider command.
2. Open Alas and select a worktree.
3. Open provider settings and add a global provider with command/args.
4. Authenticate from Alas if the provider reports auth is required.
5. Use `+ → Agent Chat` and select the provider.
6. Send a prompt and confirm streamed transcript updates appear.
7. Trigger a file read/write or terminal command and confirm the tool card shows the side effect under Allow Everything.
8. Restart Alas and confirm the chat returns.
9. Confirm the composer is enabled only if ACP resume succeeds; otherwise the transcript is read-only.

## ACP Provider Auto-Discovery

1. Ensure `opencode` is installed and available on `PATH`.
2. Start Alas with no configured `opencode` provider.
3. Open Provider Settings and confirm OpenCode appears with command `opencode` and args `["acp"]`.
4. Disable OpenCode, restart Alas, and confirm it stays disabled.
5. Remove OpenCode, save settings, restart Alas, and confirm it is not re-added.
6. If `claude` or `codex` are installed, confirm they appear only as suggestions unless manually configured.

## Code Editor (tree-sitter + LSP)

Pre-req: a Swift project, `sourcekit-lsp` available via `xcrun --find sourcekit-lsp`.

### Editor pane

1. Open a worktree backed by a Swift project. Open a `.swift` file in an editor tab.
2. Confirm tree-sitter coloring is visible immediately (keywords purple, types blue, functions yellow, strings green, comments gray).
3. Wait ~30 s on a fresh checkout for `sourcekit-lsp` to settle. Hover over a function name and confirm a popover appears with type info / docs.
4. Cmd-click a symbol and confirm the editor jumps to its definition (same tab if same file, new tab otherwise).
5. Introduce a syntax error (e.g. `let x =`). Save. Confirm a dotted underline appears under the offending range within ~2 s.
6. Close all editor tabs for the worktree and confirm the language server shuts down (`pgrep sourcekit-lsp` no longer lists the worktree's instance).

### Diff pane

1. Stage a Swift change. Open the diff tab.
2. Confirm hunks render with colored keywords / types / strings.
3. Wait for `sourcekit-lsp` to settle. Hover a symbol on the new/current side and confirm a type/docs popover appears.
4. Cmd-click a symbol on the new/current side and confirm the editor jumps to its definition.
5. Hover or Cmd-click deleted/old-side lines and confirm no LSP popover or navigation occurs.
6. Switch between split and stacked diff layouts and repeat the hover / Cmd-click checks on the new/current side.

### Settings → Code

1. Open Settings → Code. Confirm Swift is listed with a status badge.
2. Edit the Swift entry, change the args (e.g. add `--log-level info`), Save. Restart Alas. Confirm the new args persist.
3. Add a custom language entry (e.g. Rust → `rust-analyzer`). Save. Restart. Confirm the entry persists.
4. Disable Swift. Reopen a `.swift` file. Confirm tree-sitter coloring still works but hover / diagnostics / go-to-def are gone.
5. Re-enable Swift. Reopen the file. Confirm hover and diagnostics return after the server initializes.

## Editor — editable files (v1)

Run from a real worktree with at least one Swift file and one CRLF text file.

- **Save round-trip.** Open a Swift file, type a comment, ⌘S. `git status` shows the file modified.
- **Tab persistence.** Open a file, type, switch tabs, switch back. Content preserved.
- **Hot exit.** Open a file, type, ⌘Q without saving. Relaunch. Tab restored, dirty dot present, content matches what you typed.
- **External change while clean.** Open a file (do not edit). In a terminal, append a line to the file. The editor reflects the new line within ~1 s.
- **External change while dirty.** Open a file, type a character, then in a terminal `echo z >> path`. The conflict banner appears. **Reload from disk** discards edits and shows external content. **Keep mine** keeps your buffer; subsequent ⌘S overwrites the external change.
- **Deletion conflict.** Open a file, type, then `rm` it externally. Banner shows "File was deleted on disk." **Save anyway** recreates it; **Keep mine** leaves the buffer in place (without writing).
- **CRLF preservation.** Drop a CRLF-encoded text file in the worktree (`printf 'a\r\nb\r\n' > win.txt`). Open it, append a line, ⌘S. `xxd win.txt` shows the new line as CRLF as well.
- **Permissions preservation.** `chmod 755` a script file, open it, edit, ⌘S. `ls -l` still shows `-rwxr-xr-x`.
- **Big file responsiveness.** Open a 5 k-line file, type rapidly. No visible flicker. Diagnostics catch up within ~1 s of pause.
- **Save failure.** `chmod 555` the parent directory, edit, ⌘S. The conflict-banner area shows "Couldn't save: …". Restore perms, ⌘S succeeds.

## Terminal Commands

Inside an Alas-spawned terminal:

- `type alas` reports the script path under Alas's per-user bin dir.
- `alas open README.md` opens the file in the editor.
- `alas open README.md --line 10 --end-line 12` opens the file, scrolls to line 10, and temporarily highlights lines 10–12.
- `alas open README.md -- --line` treats `--line` as a second filename, preserving flag-shaped paths.
- `alas wt list` prints the visible worktrees and marks the current one.
- `alas wt switch <name-or-branch>` focuses the matching worktree.
- `alas wt new manual-test-branch --base main` starts worktree creation and shows progress in the sidebar.
- On a disposable worktree, `alas wt delete <name-or-branch>` starts deletion; dirty worktrees are rejected unless rerun with `--force`.
- `alas review` opens the local Changes review tab.
- In a GitHub- or GitLab-backed worktree, `alas review <number-or-url>` opens the provider PR/MR review session.
- `type ao` reports the script path under Alas's per-user bin dir (same directory as `alas`).
- `ao README.md` opens the file in the editor (identical behavior to `alas open README.md`).
- `ao` with no arguments prints `usage: alas open <path> [path...]` and exits with a non-zero status.
- Launching a terminal **outside** Alas, `type ao` reports `ao: not found` (or the shell's equivalent).
- Launching a terminal **outside** Alas, `type alas` reports `alas: not found` (or the shell's equivalent).

## Review Loop Drawer

1. Open a GitHub-backed worktree on a branch with local commits.
2. Confirm the Changes tab shows a bottom review-loop drawer.
3. Confirm missing `gh` auth or missing `gh` appears as the primary next action when applicable.
4. On an unpublished branch, click "Start" and confirm the next action becomes push.
5. On a branch with an open PR, confirm the drawer shows `GitHub #<number>` and compact check/review/merge status.
6. For a failing check, confirm "Open in agent" creates an ACP tab with a focused handoff prompt.
7. Confirm merge, comment posting, review-thread resolution, force-push, and editing-agent runs are not executed without explicit user action.

### Draft PR generation

1. Open a worktree branch with committed changes ahead of the selected base branch and no existing PR.
2. Expand the review readiness drawer and click Create PR.
3. Confirm a Draft PR tab opens with normal PR mode selected and Draft unchecked.
4. Click the sparkle button with an enabled AI tool.
5. Confirm title/body are filled with Summary and Testing sections.
6. Toggle Draft, then create the PR from a disposable branch or cancel before submission during local-only testing.

## Native GG Workflows

Use a disposable GG repository with at least three mutable stack commits and a
remote test repository. Keep a terminal open in the selected worktree so Git
and GG state can be checked independently after every action.

### Non-GG Prepare

1. Select a non-GG worktree with one staged file and one unstaged file.
2. Expand Prepare and confirm the existing review and commit-draft actions are present, without GG destinations.
3. Review the current changes and confirm both staged and unstaged changes appear in the local Changes review.
4. Create a commit from the staged change and confirm the unstaged file remains under Changes.
5. Confirm no GG stack drawer or GG mutation status appears.

### GG Prepare

Prerequisite: use the paired native-client GG build with `sc --staged-only` and `--client-operation-id` support. Amend and immediate Undo are capability-gated when either contract is unavailable.

1. Select a GG worktree checked out at the stack head (required for `New stack commit`) with one staged file and one unstaged file.
2. Confirm Prepare and the GG stack drawer are visible at the same time.
3. Confirm Prepare shows `Review current changes`, `New stack commit`, `Amend current`, and `Absorb into stack` in that order.
4. Run `Review current changes` and confirm both staged and unstaged changes appear in the local Changes review.
5. Open `New stack commit`, commit the staged change, and confirm the stack refreshes while the unstaged file remains under Changes.

### GG staged-only Amend

1. In a GG worktree, stage one file and leave a second file unstaged.
2. Expand Prepare and select `Amend current`.
3. Confirm the current stack commit includes only the staged diff.
4. Confirm the unstaged file remains under Changes and the stack refreshes.
5. Run `Undo Last GG Operation` and confirm the prior stack commit is restored.

### GG staged-only Absorb

1. In a GG worktree with at least two matching stack commits, stage hunks that GG can absorb and leave another file unstaged.
2. Expand Prepare and select `Absorb into stack`.
3. Confirm GG assigns only the staged hunks to the matching stack commits.
4. Confirm the unstaged file remains under Changes and the rewritten stack commits refresh.
5. Run `Undo Last GG Operation` and confirm the pre-absorb stack is restored.

### GG PR review versus local Review Commit

1. Sync a stack commit so it has a mapped PR or MR, then open that commit's context menu.
2. In the `GG` submenu, select `Review PR in Alas...` or `Review MR in Alas...` and confirm Alas opens the provider review with its remote diff and comments.
3. Return to the commit context menu and select the top-level `Review Commit…` action.
4. Confirm the top-level action starts a local agent review of that stack commit rather than opening the provider review.
5. Confirm `Open PR in Browser` or `Open MR in Browser` still opens the mapped provider page.

### GG Drop Commit

1. Choose a mutable middle stack commit with at least one descendant and open `GG` > `Drop Commit...`.
2. Confirm the prompt names the selected stack commit, gives the descendant rewrite count, and warns if it has an open PR or MR.
3. Confirm the operation and verify only the selected stack commit is removed while its descendants remain in rewritten form.
4. Confirm the stack, Changes, review state, and GG Inbox refresh.
5. Run `Undo Last GG Operation` and confirm the dropped stack commit and descendant identities are restored.

### GG Split Stack with a worktree

1. On a stack with commits above the split point, open that stack commit's `GG` submenu and select `Split Stack Here...`.
2. Confirm the sheet shows the selected stack commit, lower stack, derived editable destination name, exact moved-commit count, and `Create a new worktree` selected (the checkbox is only enabled when the GG build supports keeping the invoking worktree; on older builds it stays selected but disabled).
3. Leave `Create a new worktree` selected and apply the operation.
4. Confirm Alas refreshes project topology, creates and selects the destination worktree, and shows the moved stack commits there.
5. Confirm the original worktree remains on the lower stack with only its retained stack commits.

### GG Split Stack without a worktree

1. With a GG version that supports keeping the invoking worktree, open `GG` > `Split Stack Here...` above the bottom stack commit.
2. Clear `Create a new worktree`, choose a valid destination name, and apply the operation.
3. Confirm Alas reports `New stack created without a worktree` and does not add or select a worktree.
4. Confirm the invoking worktree remains checked out on the lower stack.
5. Confirm the lower stack and GG Inbox refresh and the destination stack is discoverable through GG.

### GG Split Commit unavailable

1. Put a GG build that lacks either `split --describe` or `split --plan-json` first on Alas's `PATH`, then restart Alas.
2. Open a mutable stack commit's `GG` submenu.
3. Confirm `Split Commit...` is disabled and exposes `Update GG to use native Split Commit`.
4. Confirm Checkout, Drop, Split Stack, and Land actions retain their normal availability.
5. Restore a protocol-capable GG build and restart Alas before continuing.

### GG Split Commit success

1. With a GG build that supports both structured Split flags, choose a mutable stack commit containing at least two selectable text hunks and open `GG` > `Split Commit...`.
2. Select a non-empty proper subset for the new lower stack commit and enter non-empty messages for both resulting stack commits.
3. Confirm the first and remainder previews partition the selected and unselected hunks correctly.
4. Apply the split and confirm two stack commits replace the target, descendants refresh, and the temporary plan file is not left on disk.
5. Confirm `Undo Last GG Operation` restores the original stack commit and descendants.

### GG Split Commit stale-plan preservation

1. Open `GG` > `Split Commit...`, select hunks, and edit both messages without applying.
2. In another terminal, rewrite or replace the target stack commit so its GG ID, SHA, tree, or diff no longer matches the open editor.
3. Return to Alas and apply the split.
4. Confirm Alas rejects the apply and performs no rewrite. Changing the target's GG ID, SHA, or tree changes the stack identity, so expect the generic `stack changed` rejection; a stale plan against an unchanged identity is what surfaces the split-plan-stale report.
5. Confirm the selection and both edited messages remain intact until `Reload` or `Cancel` is chosen explicitly.

### GG Reorder within mutable regions

1. Prepare a stack with at least two mutable stack commits on each side of a merged stack commit.
2. Open the stack drawer menu and select `Reorder Stack…`.
3. Drag mutable stack commits within one contiguous mutable region and confirm the preview shows the complete resulting order.
4. Confirm an immutable stack commit stays fixed and a drag across its boundary is rejected; confirm the sheet offers no Drop action.
5. Apply a valid order and verify GG receives that exact stable-ID order and the refreshed stack matches it.

### GG Restack preview

1. Prepare a stack whose parent relationships require repair, then select `Restack…` from the stack drawer menu.
2. Confirm Alas runs the dry-run first and displays each planned rewrite with its current and expected parent before offering Apply.
3. Cancel and confirm the stack is unchanged, then reopen the preview.
4. Change the stack externally before applying and confirm Alas rejects the stale preview without rewriting.
5. Reopen a fresh preview, apply it, and confirm the resulting stack matches the displayed plan; when the dry-run has no work, confirm Apply is disabled.

### GG config-aware Sync and Rebase

1. Put the stack behind its base branch, set effective `sync_auto_rebase` to `true` and `sync_behind_threshold` to a positive value no greater than the current behind count, refresh, and confirm `Sync stack` remains primary with `Includes rebase onto <base>` (the rebase detail only appears once the behind count meets the threshold).
2. Run Sync and confirm GG applies its effective sync policy, including the rebase, without Alas adding force or policy overrides.
3. Set effective `sync_auto_rebase` to `false` and `sync_behind_threshold` to a value of at least `2`, no greater than the current behind count, then refresh.
4. Confirm `Rebase onto <base>` replaces Sync; run it and confirm the normal GG rebase executes without force.
5. Put the stack behind again by a positive count less than `sync_behind_threshold` and confirm `Sync stack` is primary instead of Rebase.

### GG paused Continue and Abort

1. Start a local GG rewrite that produces conflicts and confirm the operation pauses instead of being rolled back automatically.
2. Confirm the stack drawer replaces other primary actions with `Continue` and `Abort`, and the existing Conflicts section exposes the conflicted files.
3. Resolve the conflicts and select `Continue`; confirm the original GG operation completes and all affected views refresh.
4. Produce another paused rewrite, select `Abort`, and confirm GG restores its pre-operation state.
5. Confirm neither recovery path is treated as a new unrelated Undo candidate.

### GG local Undo

1. With a GG build that supports client operation IDs, perform a successful local Amend, Absorb, Drop, Split, Reorder, or Restack operation in Alas.
2. Confirm `Undo Last GG Operation` becomes enabled and remains available after collapsing the drawer and after relaunching Alas.
3. Select Undo and confirm Alas revalidates the newest GG operation before executing it.
4. Confirm the prior stack state is restored and all stack, Changes, review, and Inbox surfaces refresh.
5. Perform another local mutation and confirm the older operation is no longer offered for Undo.

### GG remote Undo refusal

1. Complete a Sync or Land operation and confirm it does not create an enabled `Undo Last GG Operation` action.
2. Perform a local undoable rewrite so Undo appears, then change the related remote state from another client before selecting Undo.
3. Select Undo and allow GG to reject the now remote-ineligible or stale operation.
4. Confirm Alas displays GG's recovery hint and does not attempt a force, alternate rollback, or silent local reset.
5. Confirm the refusal keeps the recovery candidate and marker intact (Alas does not clear them on a remote-state refusal), so if GG still lists the same operation the drawer keeps offering it; a fresh local mutation is what supersedes it, and each Undo attempt re-validates before executing.

### GG Sync with uncommitted changes

1. Prepare an unsynced GG stack that is not behind its base (or is behind by less than `sync_behind_threshold` with `sync_auto_rebase = false`), so `Sync stack` is the primary action rather than Rebase, then leave an unrelated tracked file modified and an untracked file in the worktree.
2. Expand the stack drawer and confirm `Sync stack` remains available with `Local changes are not included`.
3. Run Sync and confirm only committed stack content is published.
4. Confirm both local files remain unchanged under Changes after the stack and provider state refresh.
5. If GG refuses because the stack base became stale, confirm Alas refreshes and presents Rebase without automatically retrying Sync.
