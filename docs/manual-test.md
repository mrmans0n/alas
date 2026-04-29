# Alas Manual Test Script

## Repository/worktree smoke test

1. Start Alas with `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" cargo run`.
2. Add an existing Git repository.
3. Confirm its main worktree appears in the sidebar.
4. Create a new worktree from `HEAD` with branch `alas-manual-test`.
5. Confirm the new worktree is selected automatically.
6. Confirm the terminal command starts in the new worktree directory.
7. Switch back to the main worktree, then back to the new worktree.
8. Confirm terminal session output is preserved.
9. Modify a file and confirm the right Git inspector shows it.
10. Archive the linked worktree and confirm it disappears.
11. Enable show archived for the repository and unarchive it.
12. Remove the linked worktree with confirmation.
13. Prune stale worktrees with confirmation.

## Terminal input, resize, and lifecycle smoke test

1. At a shell prompt, type and edit a command; confirm printable input, Enter, Backspace, and Tab work.
2. Run a few commands, then press Up/Down; confirm shell history navigation works.
3. Press Left/Right inside an editable command; confirm cursor movement works.
4. Press Ctrl-C while a foreground command is running; confirm the command is interrupted.
5. Press Escape and verify the shell/TUI receives it where applicable.
6. Press Option/Alt-f and Option/Alt-b in a readline shell; confirm common Meta movement works via ESC-prefix input.
7. Run `stty size`, resize the Alas window, then run `stty size` again; confirm rows/columns change with the terminal body.
8. For startup failure, use a disposable worktree and temporarily rename/delete its directory before opening or retrying its terminal; confirm the failed tab shows command, cwd, cause, Retry, and Edit Command.
9. Restore the disposable worktree path and click Retry; confirm only that tab restarts and other tabs remain alive.
10. Run a short-lived command tab (for example `printf done` or `does-not-exist`); confirm the final screen remains visible with an exited status and Restart button.
