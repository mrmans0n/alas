# `/btw` side questions in ACP tabs

## Goal

Ask a quick side question while the main ACP session keeps working. The answer
comes from a temporary, read-only fork of the current session, is shown in a
floating card above the composer, and never enters the main transcript or the
main agent's context.

ACP has no standard side-question operation, and adapters pass slash commands
through as ordinary prompts, so this is an Alas feature built on the existing
fork machinery.

## Decisions

- **Entry:** `/btw <question>` in the composer. It is the first Alas-handled
  slash command. It never queues or steers the main session. Empty `/btw` opens
  the card with focus in its field.
- **Picker:** `/btw` is listed in its own "Alas" group with a source badge. If
  the adapter advertises its own `/btw`, Alas wins and the agent's entry is
  hidden.
- **Context:** native `session/fork` when eligible, otherwise transcript transfer
  (`session/new` + `ACPTranscriptMarkdown.forkContext`).
- **Tools:** read-only. Follow-ups are allowed in the card.
- **Surface:** floating card overlaid above the composer (option A of the
  mockups). One per tab; a new `/btw` replaces the current one.
- **Lifecycle:** ✕ / Esc discards the side session. "Keep as session" promotes it
  to a normal forked session.

## Architecture

The fork pipeline cannot run outside SQLite: `createFork` and
`startForkTarget` write the row, messages, and fork record, and the runner
requires persistence to start. Leases, broker cursors, and helper-proc offsets
are keyed by row. Rather than duplicating the runner, the side session is a
normal persisted fork row flagged as hidden. That also makes "Keep as session"
nearly free.

New folder `Alas/Sources/ACP/SideQuestion/`:

- `ACPSideQuestion.swift` — pure decision logic:
  - `ACPAlasSlashCommand.parse(text:) -> .btw(question:)?`
  - `ACPSideQuestionBoundaryPolicy.boundary(messages:isTurnActive:)`
  - `ACPSideQuestionPermissionRule.decide(kind:) -> .allow | .ask | .reject`
  - `ACPSideQuestionModePolicy.preferredModeID(modes:currentModeID:)`
  - `ACPSideQuestionState` and a reducer. States: `composing`,
    `startingFork`, `streaming`, `answered`, `failed(message)`, with
    orthogonal `isCollapsed` and `blockedNotices`.
- `ACPSideQuestionController.swift` — `@MainActor` observable, one per parent
  session. Holds the side session id, question, timing, and reducer state, and
  observes the side session's streaming state. Owned by the manager as
  `sideQuestions: [ACPSession.ID: ACPSideQuestionController]` so it survives view
  rebuilds and tab close can reach it.
- `ACPSideQuestionCard.swift` — the view. Renders the side session's transcript
  directly instead of embedding the AppKit `ACPMessageList` scroller. Agent text
  reuses `ACPMarkdownText` / `ACPTranscriptRowContent`; tool calls render as
  one-line summaries; earlier turns collapse to their question. Follow-ups go
  through `manager.submit` on the side session. `fetch` permission prompts reuse
  `ACPPermissionPrompt`.

## Hiding the side session

The seam is a single `sessions.ephemeral_parent_id` column:

- Filtered out in `recentSessions` and the forks join; skipped when inserting
  into the in-memory `recent` list. No tab is ever created for it.
- Title generation, summaries, next-prompt suggestions, and turn-completion
  notifications skip restricted sessions.
- Dismiss calls `deletePersistedSession(id:)`, which closes the remote session,
  tears down the process, and deletes the row (messages and fork record cascade).
- On launch, `purgeOrphanedEphemeralSessions()` removes leftovers from a crash,
  including releasing any broker namespace.

## Read-only enforcement

A gate runs first in `ACPPermissionPolicy.evaluate`, before auto-run and the
decision-log lookup, so a remembered "always allow edit" cannot let writes
through:

| Tool kind | Decision |
|---|---|
| `read`, `search`, `think` | Allow once (never "always") |
| `fetch` | Ask in the card |
| `edit`, `delete`, `move`, `execute`, `switch_mode`, `other`, unknown, nil | Reject, show "Blocked …" notice |

Reads are auto-allowed because a side card that stops on every grep is useless,
and reads cannot mutate anything; the runner's outside-worktree read refusal
still applies. `fetch` asks because it is the one read-ish kind that sends data
off the machine.

Mode policy: prefer a mode with `kind == .plan`; else, if the current mode is
full-access or auto-review, switch to standard; else keep it. `submit` already
waits for pending mode selections, so the first prompt cannot race the switch.
Auto-run is forced off.

Client capabilities are not a gate: some adapters write files directly when the
client does not advertise `writeTextFile`. Mode plus permission rejection is the
enforcement.

## Fork boundary

Native `session/fork` forks the remote head and requires an idle source runner
(native fork barrier: idle, empty queue, no active prompt) plus a broker
connection.

- **Idle parent:** boundary is the last message; the existing candidate policy
  picks native when eligible.
- **Mid-turn parent:** boundary is the last agent message before the latest user
  message. That is not the remote head, so the candidate becomes transcript
  transfer. The in-flight tail may not be persisted yet, so
  `ACPSessionForkSnapshotResolver.resolve` gains `allowsUnpersistedTail`, which
  only requires the stored prefix up to the boundary.
- **No completed turn:** start a blank ephemeral session.

## Keep as session

`promoteSideQuestion(parentID:)` clears `ephemeral_parent_id`, records
`session_forks.via = 'btw'`, inserts into `recent`, lifts the read-only
restriction (auto-run stays off), and drops the controller without disposing the
runner. `AppState` opens a tab for it, mirroring `forkACPSession`. The fork
divider reads "Forked from … via /btw".

## Implementation order

1. **Store seam:** v21 migration (`sessions.ephemeral_parent_id`,
   `session_forks.via`), row and record fields, `recentSessions` filter, orphan
   purge.
2. **Forking:** boundary policy, `allowsUnpersistedTail`,
   `createFork(ephemeralParentID:)`, `startSideQuestion`, `dismissSideQuestion`,
   `promoteSideQuestion`.
3. **Read-only:** permission gate, mode policy, `readOnlyRestricted`, and
   opting restricted sessions out of titles, summaries, suggestions, and
   notifications.
4. **Entry:** `ACPAlasSlashCommand.parse`, picker catalog merge with the Alas
   group and badge (also when the agent advertises no commands), composer chips,
   interception in `ACPTabView`'s submit closure.
5. **Card:** controller, reducer, view, overlay in `chatSurface`, ⌘. collapse,
   Esc dismiss, Copy and Insert into composer, tab-close hook in `AppState`.
6. **Keep as session:** promotion, tab opening, "via /btw" divider.

## Tests

Extend existing suites:

- `ACPSessionStoreTests` — migration adds the columns; `recentSessions` excludes
  ephemeral rows; orphan lookup.
- `ACPSessionForkPolicyTests` — parameterized boundary cases: idle, mid-turn with
  agent text, mid-turn with only tool calls, empty, single user message.
- `ACPSessionForkManagerTests` — ephemeral fork absent from `recent` and deleted
  on dismiss; promote makes it visible with `via == .btw`; resolver accepts an
  unpersisted tail only when allowed.
- `ACPPermissionPolicyTests` — parameterized kind → decision; a remembered
  project-scope allow plus auto-run still rejects `edit` while restricted.
- `ACPSlashPickerTests` — parameterized merge: agent `/btw` hidden, Alas group
  first, `/btw` present with no agent commands.

New `ACPSideQuestionPolicyTests` for `parse` (parameterized), mode policy, and
reducer transitions.

Not tested: card layout, overlay placement, keyboard wiring, Copy/Insert,
`closeTab` forwarding, `deletePersistedSession` (already covered).

## Risks and open questions

- **Remote/SSH:** works without extra code, always via transcript transfer
  (no broker), with slower startup from the extra SSH and adapter spawn.
- **Adapter session lists:** the adapter's own store (e.g. Claude JSONL) keeps the
  closed side session, so it may appear in "browse agent sessions". Mitigate
  with `session/delete` on dismiss when supported.
- **MCP tools** usually report kind `other` and get blocked, which may be too
  strict for read-only MCP tools.
- **Mirrors:** forking a mirror session fails because the writer lease is held
  elsewhere; disable `/btw` there.
- **Origin on Keep:** use `.agentForked` only for native forks and rely on
  `via = .btw` for the divider in both cases, to avoid changing restore policy
  for transcript-transfer forks.
- **Cost:** one extra adapter process per tab with an open card.
