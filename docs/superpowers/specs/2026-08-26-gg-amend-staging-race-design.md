# GG Amend Staging Race Design

## Problem

Alas projects staging changes into the UI before the serialized Git staging
queue has applied them to the index. This makes `Amend current` and `Absorb
into stack` available while `git add` is still running. If either GG command
starts first, it can read an empty or partial index and complete without the
changes shown as staged in Alas.

## Design

Keep the optimistic staging UI. When a staged-change GG action is selected,
reserve the action immediately so its controls become disabled, then await the
existing staging worker before invoking GG. Apply this at the shared GG
mutation boundary for both Amend and Absorb rather than in the button handler.

If every queued staging mutation succeeds, execute the existing command
unchanged. Amend remains `gg sc --staged-only`; Absorb remains `gg absorb -s`.
If staging fails, stop before invoking GG and preserve the staging error for
the user.

## Testing

Add one regression test that suspends staging, starts Amend, and verifies the
GG executor has not run. After staging resumes successfully, verify Amend
executes once. Cover the shared request classification so Absorb cannot regain
the same race.

Run the focused optimistic-staging and GG mutation tests, then the repository's
required XcodeGen, build, and test commands.

## Out of Scope

- Replacing optimistic staging with disabled controls.
- Adding a global queue for every Git and GG operation.
- Changing GG commands, staging semantics, or the Changes layout.
