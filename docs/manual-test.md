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
