# Alas Manual Test Script

1. Start Alas with `cargo run`.
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
