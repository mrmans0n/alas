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

## Terminal Tabs

1. Select a worktree.
2. Confirm the default terminal tab starts in that worktree.
3. Create a second terminal tab from the configured-command picker.
4. Switch tabs and confirm output/process state is preserved.
5. Switch worktrees and return; confirm tabs still exist for the original worktree.
6. For a short-lived or failed command tab, confirm the final screen remains visible with exited/failed status plus Restart or Retry controls.
7. For startup failure, temporarily make a disposable worktree path unavailable; confirm the failed tab shows command, cwd, cause, Retry, and Edit Command, then restore the path and retry.

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

## Files and Changes Inspector

1. Files tab shows worktree files.
2. Changes tab shows modified/untracked files.
3. File loading errors do not break terminal input.
