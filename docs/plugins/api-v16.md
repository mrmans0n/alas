# Plugin API 16: run execution identity

API 16 makes exact run identity available to scripts at their execution boundary.
A capture wrapper can use it to associate immutable reports with the same run ID
the plugin receives in `run/started`, `run/finished` and report command targets.

Every Alas run script receives these environment variables before its code runs:

| Variable | Value |
|---|---|
| `ALAS_RUN_ID` | The exact run record's unique ID, unchanged through completion. |
| `ALAS_RUN_SCRIPT_KEY` | The script key, such as `repo:test.sh`. |
| `ALAS_WORKTREE_ID` | The owning worktree ID, as used in plugin requests/events. |
| `ALAS_PROJECT_ID` | The owning project ID. |

The existing `ALAS_WORKTREE_ROOT`, `ALAS_REPO_ROOT`, `ALAS_BRANCH` and
`ALAS_PROJECT_NAME` remain available. Identity is composed by the shared launcher
for terminal, hidden/headless and SSH invocations, with normal shell quoting.
IDs are opaque strings; a worktree ID is not necessarily a filesystem path.

A plugin that requires this contract must declare `"api": 16`. Older hosts
refuse it rather than offering an unreliable callback-time substitute. No extra
capability or protocol request is introduced. Run events and run output are
unchanged; a callback is not evidence of the source state at process start.

Run identity is correlation within the user's execution environment, not a
signature or protection against user-authored scripts fabricating evidence.
Scripts launched outside Alas do not have this contract. Capture wrappers should
validate all identity fields, use isolated output paths, preserve source evidence,
and leave legacy imports unassociated when validation is unavailable.
