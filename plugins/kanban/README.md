# Kanban

A small ticket tracker for a project whose tickets start agents. Starting a
ticket creates a worktree and starts an agent with the ticket's title and
description; the ticket then follows its session, and the agent's final reply
is added to it as a comment. It uses plugin API 3 (view tabs, `task/start`,
`session/last_message`, `agent/list` and storage) and is the reference plugin
for that API.

## Build and install

From the repository root:

```bash
rustup target add wasm32-unknown-unknown
plugins/kanban/build.sh
```

`build.sh` works from any directory and installs into
`~/Library/Application Support/Alas/Plugins/kanban`. Set
`ALAS_APP_SUPPORT_DIR` to install into an isolated Alas profile instead.

Then turn on **Settings → Debug → Experimental → Plugins** (it only shows when
`~/.alas/.debug` exists), open **Settings → Plugins**, click **Approve…** on
Kanban, and open **View → Plugins → Board**.

## Tickets

A ticket is numbered `KAN-<n>`. Numbers are never reused, even after a delete.
It has a title, a description, a priority (No priority, Low, Medium, High,
Urgent), an optional assignee, and comments.

The board has five columns, one per status: **Backlog**, **Todo**,
**In progress**, **In review** and **Done**. **Show cancelled** adds a
**Cancelled** column. A card shows the number, title, priority, assignee and,
when the ticket has a session, the agent's state. Click a card to open its
ticket screen.

### Creating a ticket

The **New ticket** form sits above the board. Type a title (Return keeps it),
pick a priority and an assignee, then type the description and press ⌘Return
to create the ticket. Without a title, the description's first line becomes
the title. **Create** makes a ticket from the title alone. New tickets start in
Backlog.

### The ticket screen

- **Back** returns to the board.
- Status, priority and assignee menus. The assignee menu lists the agents Alas
  can start, refreshed each time a ticket opens.
- The description, saved when you press ⌘Return in it.
- Comments, oldest first, from **You** or the **Agent**, and a field to add
  one (⌘Return posts it).
- **Cancel ticket** and **Delete**.

### Starting an agent

**Start** creates a new worktree on branch `task/kan-<n>` and starts the
assignee there, or the project's default agent when the ticket is unassigned.
The prompt is `KAN-<n>: <title>` followed by the description. Start is offered
while the ticket is open (not Done or Cancelled) and has no running session.
If the start is refused, the ticket keeps its status and shows the reason.

A started ticket follows its session: running, waiting for input or for
permission → **In progress**; idle or ended → **In review**. A status you set
by hand holds until the session's state changes again. Done and Cancelled stop
following. **Open session** focuses the agent's session.

When a followed session goes idle after running, the plugin fetches the
agent's last reply once with `session/last_message` and adds it to the ticket
as an **Agent** comment.

## Upgrading from the card board

A board saved by the earlier card version of this plugin is converted on first
load: each card becomes a ticket, numbered in card order, with its prompt as
the description and its session carried over. Columns map to statuses:
Backlog → Backlog, Running and Needs you → In progress, Review → In review,
Done → Done. Prompts longer than 4,000 characters are cut, because that is the
most a text field can edit. The old `board` key is left in place, so nothing
is lost and an older plugin build still finds its board.

## Storage and caps

Tickets are saved per project in the plugin's storage: `meta`, an `index` with
one small record per ticket, and one `ticket-<n>` key per description and
comments. The board reads only the index; a ticket's body is read when its
screen opens or an agent comment arrives.

| Cap | Value |
|---|---|
| Tickets in the index | 75 |
| Done and Cancelled tickets kept in the index | 15, the oldest-closed leave first |
| Title | 200 characters |
| Description | 4,000 characters |
| Comments per ticket | 10, the oldest dropped first |
| Comment | 2,000 characters; a longer agent reply is cut |
| Labels | 8 of 32 characters |

Alas gives every plugin call a fixed fuel budget, and parsing, saving and
drawing tickets costs fuel per ticket and per byte. The index cap keeps the
costliest board call under half the budget, and the comment caps do the same
for opening a full ticket or adding a comment to it. Archived tickets leave the index
and their bodies are deleted. When the tracker is full, a new ticket is
refused until you delete some.

## Known limits

- **Create** drops a description you have typed but not submitted. Press
  ⌘Return in the description instead.
- If Alas quits while a ticket is starting, the ticket is not linked to the
  worktree and agent that were created: after a relaunch it moves to In review,
  and **Start again** makes a second worktree.
- Text dense with quotes, backslashes or line breaks costs more fuel to read.
  A full ticket of such text stays within a plugin call's budget but uses more
  than half of it.
- All of a project's tickets share the plugin's 1 MB of storage. When it is
  full, saving shows an error.
