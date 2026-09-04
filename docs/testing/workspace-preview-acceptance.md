# Workspace Preview Acceptance

This record belongs to the Workspace V1 Debug preview. The preview flag must
remain default-off for this implementation issue.

## Required automated validation

Run these before publishing a preview build:

```bash
rtk xcodegen
git diff --check
cargo test --manifest-path AlasCLI/Cargo.toml --workspace --locked
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
rtk xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

## Local multi-repository preview run

Use at least two local repositories that already exist as Projects in Alas.
Record the repository paths, Project IDs, and the created Workspace Checkout ID.

1. Confirm `Settings > Debug > Workspace Preview` is off by default.
2. With the flag off, confirm no Workspace creation, checkout creation, CLI,
   MCP, search, notification, or lifecycle path can mutate `workspaces.json`.
3. Enable the Debug preview flag.
4. Create a Workspace from two existing Projects on the same execution location.
   Confirm the active Space shows the Workspace as a peer of existing Projects.
5. Rename Projects and the Workspace. Confirm existing checkout roots,
   member destinations, Terminal sessions, ACP sessions, and Work Item
   attribution remain stable.
6. Create a Workspace Checkout. Confirm preflight reports every deterministic
   problem before any Git mutation. On success, confirm `.alas-workspace-checkout.json`
   exists at the checkout root before member worktrees are created.
7. Confirm shared Terminal and ACP tabs are owned by the Workspace Checkout and
   member panes use explicit Repository Focus for the selected member only.
8. Open search with the Workspace Checkout selected. Confirm the Workspace
   Checkout scope searches only available checkout members and reports partial
   per-member failures.
9. Run CLI and built-in MCP `workspace list`, `workspace show`, `workspace switch`,
   and `workspace focus` by UUID. Confirm output is versioned JSON where
   applicable, errors are stable and nonzero, and focus requires `--member`.
10. Simulate interruption at each persisted checkpoint by relaunching after
    plan persistence, branch preparation, worktree creation, setup failure,
    archive, cleanup plan persistence, worktree removal, and branch deletion.
    Confirm Resume Creation, Retry Setup, Archive, Unarchive, Delete, and Forget
    keep using frozen paths, commits, branch intent, lineage, and cleanup
    ownership.
11. Delete or move one member worktree externally. Confirm reconciliation marks
    the member Needs Attention without adopting an independent worktree.
12. Archive and unarchive the checkout. Confirm shared sessions stop on archive,
    legacy Worktree tabs restore unchanged, and the checkout can be selected
    again after unarchive.
13. Delete members and then the checkout. Confirm dirty/untracked/submodule
    preflight blocks destructive cleanup, reused branches are preserved, and
    attempt-created unmerged branches require separate confirmation before
    forgetting the record.
14. Disable the Debug preview flag. Confirm existing Project, Space, Worktree,
    Terminal, ACP, file, review, and GG behavior is unchanged.

## Downgrade and re-upgrade run

1. Create a Workspace and a Workspace Checkout with mixed Project/Workspace
   Space ordering.
2. Launch an older build that does not understand typed Workspace Space members.
3. Reorder Projects in the Space and quit the older build.
4. Reopen this preview build. Confirm Workspace records remain in
   `workspaces.json`, Project order changes are merged, and Workspace placement
   is restored without importing independent worktrees.
5. Corrupt a copy of `workspaces.json` and relaunch. Confirm the file is
   quarantined, recovery is visible, and ordinary saves do not overwrite it.

## Shared SSH-host preview run

Use one real SSH host configured as an Alas execution location. Record the host
alias, remote checkout root, and the created Workspace Checkout ID.

1. Create a Workspace whose members all resolve to the exact same SSH host.
2. Confirm preflight rejects different hosts, missing roots, occupied
   destinations, checked-out branches, unsafe branch reuse, and duplicate
   destinations before persistence or Git mutation.
3. Create a remote Workspace Checkout. Confirm the manifest is written through
   shell transport, not a remote-helper API, and remote Terminal startup exports
   only the approved `ALAS_WORKSPACE_*` environment values.
4. Open shared Terminal and ACP sessions. Confirm restore uses the checkout
   root only when the saved execution location matches, and frozen MCP
   descriptors do not retarget after Project focus/config changes.
5. Run CLI and MCP list/show/switch/focus against the remote checkout by UUID.
   Confirm repository-specific operations require explicit member UUIDs.
6. Relaunch with the SSH host unavailable. Confirm checkout ACP restore remains
   pending and no live Project focus is substituted.
7. Restore the host and confirm reconciliation classifies exact persisted
   lineage only; no independent worktree is imported or adopted.
8. Archive, unarchive, delete, and forget the remote checkout. Confirm cleanup
   verifies execution location, path, lineage, and branch ownership before each
   destructive step.

## Manual record

Fill this before shipping the preview:

| Area | Result | Evidence |
| --- | --- | --- |
| Automated validation | Pending |  |
| Local multi-repository run | Pending |  |
| Downgrade/re-upgrade run | Pending |  |
| Shared SSH-host run | Pending |  |
| Feature flag remains default-off | Pending |  |
| Existing Project/Space/Worktree behavior unchanged | Pending |  |
