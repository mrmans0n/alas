# Kanban tickets (follow-up to #1653)

## Goal

Turn the Kanban plugin from a board of prompt cards into a small, client-side
issue tracker whose tickets drive agents: a first step toward tools like
Paperclip and Multica, where agents work as teammates on a ticket board. The
plugin manages everything itself; there is no external tracker.

This phase delivers an **issue tracker plus assign-to-agent**. The user creates
and assigns every ticket. Autonomous queues, goals that break into sub-tickets,
and agent-written comments are out of scope (see the end).

**Exit condition:** with the Kanban plugin approved, the user creates a ticket
with a title, description and priority, assigns it to an installed agent and
presses Start. A worktree and agent appear, the ticket moves to In progress,
then to In review when the agent goes idle, and the agent's final message is
added to the ticket as a comment. The user can open the ticket, edit its
description, change status and priority, comment, and click through to the
session. Tickets survive an app restart, and a board saved by the previous
version of the plugin is converted on first load.

## Decisions already made

- Everything from `2026-09-30-plugin-view-tabs-tasks-and-kanban-design.md`
  (plugin API 3, view tabs, `task/start`, storage) still holds unless stated
  here. The plugin keeps the id `kanban` and the single view tab `board`.
- **First slice:** issue tracker plus assigning a ticket to an agent. No
  automation yet.
- **Results flow back by an on-demand host request**, `session/last_message`,
  rather than the agent writing comments itself.
- **Storage layout:** a small index plus one key per ticket body (approach B),
  so fuel per call stays bounded as tickets accumulate.

## 1. Tickets and storage

### Ticket

| Field | Notes |
|---|---|
| `number` | Positive integer, shown as `KAN-<number>`. Assigned in order, never reused, even after delete. |
| `title` | Required, at most 200 characters. |
| `description` | At most 4,000 characters, the most a host text field can edit. |
| `priority` | `none`, `low`, `medium`, `high`, `urgent`. Default `none`. |
| `labels` | Up to 8, each at most 32 characters. Shown, not yet filterable. |
| `status` | `backlog`, `todo`, `in_progress`, `in_review`, `done`, `cancelled`. |
| `assignee` | Optional agent id. |
| `session_id`, `branch` | Set when a start is accepted. |
| `agent_state` | Last session state seen (`running`, `awaiting_input`, `permission_request`, `idle`). |
| `comments` | Oldest first, each `{author, text}`. No timestamp: the plugin has no clock. At most 50 per ticket, each at most 4,000 characters; the oldest are dropped past the cap. `author` is `you` or `agent`. |

Running, Needs you and Review are no longer columns. They are the ticket's
`agent_state`, shown as a badge, while `status` is the workflow position.

### Storage keys

| Key | Holds | Read |
|---|---|---|
| `meta` | `{version, next_number}` | On load. |
| `index` | One small record per ticket: number, title, status, priority, assignee, agent state, session id, branch. | On load; written after every change that touches a field in it. |
| `ticket-<number>` | Description, labels and comments. | When the ticket screen opens, and when a comment is added. |

- A board render uses the index alone, never a ticket body.
- **Write order:** the ticket body first, then the index, so a crash leaves at
  worst an orphan body, which is ignored. A deleted ticket has its body key
  deleted (`storage/set` with `null`) after the index drops it.
- A ticket in the index without a body is shown with an empty description and
  no comments; a body not in the index is not shown.
- **Archive:** Done and Cancelled tickets past a threshold are removed from the
  index, oldest-closed first, and their bodies stay stored. The measured caps
  are 75 tickets in the index and 15 closed tickets kept (see Fuel).
- A failed read never overwrites what is stored. The board shows a notice and
  does not save, as the current plugin does.

### Migration

On the first load with no `meta` key but an existing `board` key (the previous
format), each card becomes a ticket in the order it was added: card title →
title, prompt → description, session id, branch and agent state carried over,
and column → status (Backlog → `backlog`, Running, Needs you and Review →
`in_progress` / `in_progress` / `in_review`, Done → `done`). A prompt longer
than 4,000 characters is cut to the description cap. The old `board` key is
left in place, so a downgrade loses nothing and the full prompt survives there. A `board` that cannot be parsed
is left alone and the plugin starts with an empty tracker and a notice.

## 2. The board and the ticket screen

The plugin keeps one view tab and switches between two screens by rendering a
different tree. No host rendering change is needed.

### Board screen

- Five columns: Backlog, Todo, In progress, In review, Done. Each has a count
  badge and its own vertical scroll under a fixed header, inside the horizontal
  scroll. A **Show cancelled** toggle adds a Cancelled column.
- A card shows `KAN-12`, the title, a priority badge, the assignee, and the
  agent-state badge when there is a session. Clicking a card opens its ticket
  screen. Cards carry index data only.
- **New ticket** opens a form: title, multiline description, priority menu,
  assignee menu. ⌘Return in the description creates the ticket. The
  form-generation number in the field ids resets the fields, as now.

### Ticket screen

- **Back** returns to the board. The header shows `KAN-12`, the title, and
  status and priority menus.
- The description is an editable multiline field, saved on ⌘Return.
- **Assign to** lists the installed agents. Once assigned, a **Start** button
  runs `task/start` with the title, the description and the ticket number
  (`KAN-12`) in the prompt, and the ticket number in the requested branch name.
  Start is offered only while the ticket has no running session.
- The branch, with an **Open session** button that sends `session/focus`.
- Comments, oldest first, and a text field to add one.
- **Cancel ticket** and **Delete** at the bottom.

### Not in this phase

Drag and drop, search, label filtering, multiple boards, editing comments,
agent-written comments.

## 3. Behaviour

### Following sessions

The rules of the current plugin carry over, applied to `agent_state` and
`status`:

| Session state | Effect |
|---|---|
| `running` | `agent_state` running, `status` in progress. |
| `awaiting_input`, `permission_request` | `agent_state` set, `status` in progress. |
| `idle` | `status` in review. |
| not in the snapshot, after it was seen | `status` in review. |
| not in the snapshot, never seen yet | unchanged (still starting). |
| `unknown` | unchanged. |

- A ticket follows only while it has a session and its status is not `done` or
  `cancelled`. Changes apply only when the session state *changes*, so a manual
  status change holds until the agent's next state change.
- A snapshot that changes nothing neither saves nor renders.

### Results as comments

When a followed session first reports `idle` after being `running`, the plugin
sends `session/last_message` once for that transition and, if it returns text,
appends it as an `agent` comment (cut to 4,000 characters). Nothing is fetched
twice for one transition, and a failed or empty fetch shows a notice and never
blocks the board.

### Starting

Unchanged from the current plugin: one start in flight per plugin and project
(enforced by the host), a rejected start keeps the ticket as it was and shows
the reason, and `task/failed` for an accepted session clears that session.

### Host additions (additive to API 3)

Both need `workspace.read` and appear in `docs/plugins/api-v3.md`.

- **`session/last_message {id}`** → `{message}`. `message` is the text of the
  session's last assistant message, at most 4,096 UTF-8 bytes cut on a
  character boundary, or `null` when there is none. `id` must be a session the
  plugin's project snapshot exposes, the rule `session/focus` already follows;
  otherwise `-32003` "unknown session".
- **`agent/list`** → `{agents: [{id, name}]}`: the installed ACP agents that can
  take a prompt (the same set `task/start` accepts), in a stable order.

The SDK gains typed helpers and reply events for both.

### Fuel

A board render reads the index only, and a ticket body is read only on the
ticket screen. The plan measures a worst-case tracker (index at its cap, the
largest allowed bodies, a board with sessions on every ticket) with the
throwaway fuel probe, and sets the index cap and archive threshold so the
worst single call stays under 12.5M (the host limit is 25M). The probe is
never committed.

**Measured (2026-10-01):** with 200-character titles and a session on every
ticket, the costliest board call is the snapshot that moves a ticket: 11.6M at
75 tickets (12.3M with escape-heavy titles), 13.1M at 85, 16.5M at 100. The
index cap is 75 and 15 closed tickets are kept. Ticket bodies at the text caps
above (4,000-character description, 50 comments of 4,000 characters, about
200–400 KB) do not fit: parsing and drawing one costs 16–106M depending on how
much of the text is non-ASCII or escaped, whatever the index size. A body of
about 24,000 characters (for example 10 comments of 2,000 characters) stays
under 11M for accented text; the comment caps are a follow-up decision.

## 4. Errors and testing

### Failures

All errors are replies or notices; none stops the plugin, except that a tree
over the host limits does, so the view keeps its caps (cards per column, text
clipping, ids built only from ticket numbers).

- Storage read errors: notice, no save, nothing overwritten.
- Storage write errors (full, unavailable): a visible notice; the in-memory
  state keeps working.
- `session/last_message` or `agent/list` errors: a notice. With no agents the
  Assign menu is empty and says so.
- A ticket edited while its body is not yet loaded waits for the load; there is
  no partial write of a body.

### Rust tests

- **Reducers (kanban):** numbering is never reused after delete; session state
  to status and agent state, including manual hold and the done/cancelled stop;
  comment caps (count and size, oldest dropped); migration from `board`
  (columns map as above, old key untouched, unparseable `board` left alone);
  index and body stay consistent through create, edit, comment, delete and
  archive.
- **Render:** the board has the expected columns and card nodes, the ticket
  screen has its controls, ids are unique and within the host limits for a
  full tracker.
- **Events:** a view event for an id not in the current tree is ignored; the
  idle transition fetches once.
- **SDK:** the new request helpers encode to the documented wire shape and the
  replies decode.

### Swift tests

Extend `PluginHostTests` (no new suite): `session/last_message` and `agent/list`
without the grant return `-32001`; `last_message` returns the bounded text, cuts
on a character boundary, returns `null` with no message, and rejects a session
outside the project; `agent/list` returns the prompt-capable agents.

### Docs and live check

`docs/plugins/api-v3.md` (the two requests), `plugins/kanban/README.md`
(tickets, statuses, assignment, migration), CHANGELOG. Live check in an
isolated profile on a scratch repo: create, assign, start and watch a ticket
move; see the agent's message appear as a comment; open the session; edit and
comment; restart and see the tracker restored; seed an old-format `board` and
see it converted.

## Risks

- **Fuel:** tickets are bigger than cards. Mitigated by the index/body split
  and by measuring before setting caps.
- **Index and body drift** after a crash: handled by write order and by
  treating the index as the source of truth.
- **Last-message privacy:** a plugin with `workspace.read` can read the final
  message of any session in its project. That is a new disclosure, so the
  approval text for `workspace.read` should say so, and the message is bounded.
- **Agent list changes** while the board is open: the Assign menu refreshes on
  each ticket screen open, not live.

## Out of scope

Autonomous queues and an agent picking its next ticket, goals and epics broken
into sub-tickets, agent-written comments and status changes, dependencies,
budgets and org structure, drag and drop, search, label filters, multiple
boards, and files-in-the-repo tickets.
