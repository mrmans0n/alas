# Sticky Commit Revision Tracking Design

## Context

Commit-detail tabs and dedicated commit review sessions currently persist an
immutable commit SHA. This is correct for historical inspection, but it makes
iterative review awkward: amending or rebasing replaces commits while an open
tab continues to show the old object.

Users should be able to follow a logical single-commit revision such as
`HEAD`, `HEAD~3`, a local branch, or a tag. The logical expression must remain
stable while Alas loads each resolved commit as an immutable snapshot. Fixed
SHA tabs must keep their existing behavior.

## Goals

- Support followed revisions in commit-detail tabs and dedicated review
  sessions.
- Let users create a followed revision from an open tab or the review target
  palette.
- Follow same-branch amend, rebase, reset, and named-ref movement
  automatically.
- Preserve tab position and review continuity while the resolved SHA changes.
- Keep the last complete snapshot visible until the replacement is fully
  loaded.
- Pause before following an affected `HEAD` expression across a branch
  checkout.
- Persist pins and their review state across app restarts.

## Non-Goals

- Tracked commit ranges or branch-comparison reviews.
- Changes to hosted PR/MR, draft-commit, or commit-editor targets.
- CLI or MCP contract changes.
- Per-tab polling for Git changes.
- Rewriting comment anchors with content-based fuzzy matching.

## Model and Identity

Add a shared Codable tracked-revision value containing:

- the user-authored expression, normalized only by trimming whitespace
- the branch baseline used to distinguish same-branch rewrites from checkout
- the last completely loaded SHA
- an optional pending checkout candidate

A fixed commit remains an immutable SHA. A followed commit keeps logical
identity separate from its resolved snapshot:

- the expression owns tab/session identity and review continuity
- the resolved SHA owns commit metadata, diffs, images, and context snapshots

Commit tabs gain a stable persisted tab ID plus fixed-or-followed revision
state. Changing the resolved SHA must not change the tab ID, order, or active
selection.

Commit review sessions similarly separate their logical target identity from
the resolved commit snapshot. A followed session and its draft namespace are
keyed by worktree, repository, and normalized expression. Loaders receive only
the resolved immutable SHA.

Legacy persisted commit tabs and review sessions decode as fixed-SHA targets
with their existing identity and behavior. Converting a fixed review into a
followed review, editing its expression, or stopping following atomically
migrates its draft comments to the new logical namespace without changing the
open session's continuity.

## Entry and Presentation

Both commit-detail and review-session headers expose revision tracking:

- fixed tabs offer **Follow revision...**
- followed tabs show **Following `<expression>`** and the resolved short SHA
- followed tabs offer **Edit revision...** and **Stop following**
- the tab context menu mirrors these actions

The revision editor accepts any single expression that `git rev-parse
--verify <expression>^{commit}` resolves. Raw SHAs are valid but naturally do
not move. When the displayed commit is on HEAD's first-parent chain, the editor
suggests `HEAD` or `HEAD~N`; otherwise it starts without a relative suggestion.

Stopping following freezes the tab at its last complete SHA. It does not close,
move, or replace the visible tab.

The review target palette keeps its current commit and branch filtering. For a
nonempty query, it also validates the exact query asynchronously and, when it
resolves, presents a selectable **Follow revision `<expression>`** row. Commit
ranges continue to create immutable range targets.

Tab titles follow the loaded snapshot's subject while preserving a visible pin
indicator. Review headers and feedback context show both the expression and
resolved short SHA so the displayed bytes are never ambiguous.

## Resolution and Refresh Flow

AppState exposes a shared revision-change generation keyed by worktree. The
existing local and remote Git watchers advance it for HEAD or local-ref
movement. This avoids adding a watcher or polling loop per tab.

When a followed tab is visible or its worktree generation changes:

1. Resolve the expression and current branch.
2. If the SHA is unchanged, publish no UI or persistence change.
3. If the branch baseline is unchanged, begin loading the candidate SHA.
4. Load commit details and every diff/image/context provider against that exact
   immutable SHA in a new generation.
5. Publish metadata, diff content, resolved SHA, and title atomically only when
   the complete generation succeeds and is still current.

The prior snapshot remains interactive during resolution and loading. A small
updating indicator communicates background work without replacing the pane
with a spinner. Selection is retained by file path when the file still exists;
otherwise it falls back through the review surface's normal selection rules.

Resolution and load operations are cancellable and generation-guarded. An old
completion cannot overwrite a newer Git event, edited expression, accepted
checkout, stopped pin, or closed tab.

Inactive tabs do not poll. They revalidate when activated or when an already
instantiated view observes the shared generation.

## Checkout Safety

If the worktree branch changes and the expression resolves to a different SHA,
Alas keeps the last complete snapshot and pauses following. The tab presents a
banner with:

- **Update to new branch**, which accepts the candidate branch as the new
  baseline and loads its resolved commit
- **Stop following**, which freezes the prior complete SHA

Named expressions whose resolution is independent of the checked-out branch
continue following their own ref. A branch switch that does not change the
expression's resolved SHA requires no confirmation.

The branch baseline and pending checkout candidate persist. Reopening the app
revalidates before changing content and restores the confirmation state when
needed.

## Review Continuity

When a followed review moves to a new SHA, preserve:

- draft comments and replies
- comment resolution state
- feedback handoff history
- selected file where its path still exists
- rail collapse, layout, wrapping, and whitespace state

Existing path/side/line placement reattaches comments when the anchor remains
visible. Comments whose old line no longer maps stay visible at file level;
comments for absent files remain represented by the review summary's orphan
handling.

A verdict applies to one resolved snapshot. Moving to a new SHA clears the
verdict and returns the session to `active`, while retaining historical
handoffs. Feedback produced after movement includes both the expression and
resolved SHA.

## Failure Behavior

An invalid expression cannot create or replace a pin. Validation errors remain
in the revision editor or palette.

If an established expression later stops resolving, or its replacement fails
to load, Alas keeps the last complete snapshot and presents a nonblocking error
with **Retry**, **Edit revision...**, and **Stop following**. Interrupted rebases,
deleted refs, shallow history, and remote connection failures all use this
behavior.

Persistence is committed only with a successful complete generation or an
explicit user action. A partially loaded candidate must never be labeled as the
current resolved snapshot.

## Testing

Model and persistence tests cover:

- legacy fixed-SHA decoding
- stable followed identities and restart round-trips
- expression trimming and fixed-versus-followed deduplication
- draft migration when following, editing, or stopping
- pending checkout persistence

Resolver and coordinator tests cover:

- unchanged resolutions
- same-branch amend, rebase, and reset movement
- named-ref movement
- checkout pause, accept, and stop
- deleted or temporarily invalid refs
- cancellation and out-of-order completion suppression

Commit-tab and review-session tests cover:

- retaining the old snapshot during refresh
- atomic metadata and diff publication
- selection retention by file path
- comment placement and orphan fallback
- verdict reset to `active`
- retry and edit recovery

Palette and header tests cover validation, the synthetic followed-revision row,
`HEAD~N` suggestions, follow/edit/stop actions, errors, and accessibility
labels. Watcher tests cover local ref changes and remote HEAD movement without
per-tab polling.

Acceptance scenarios are:

- fixed SHA tabs never move
- `HEAD` follows an amend
- `HEAD~3` follows a rebase
- checkout pauses an affected HEAD-relative pin
- accepting checkout follows the new branch
- a broken expression retains the last good diff
- closing and reopening preserves the pin and review drafts

Verification runs focused Swift Testing suites first, then `xcodegen`, the
required macOS build, and the full test suite.
