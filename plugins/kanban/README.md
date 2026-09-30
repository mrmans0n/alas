# Kanban

A board of task cards for a project. Starting a card creates a worktree and
starts an agent with the card's prompt; the card then follows its session
across the board. It uses plugin API 3 (view tabs, `task/start` and storage)
and is the reference plugin for that API.

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

## Using the board

Columns: **Backlog**, **Running**, **Needs you**, **Review** and **Done**.

- Add a card at the top of Backlog: type a title and press Return, then type
  the prompt and press ⌘Return. Without a title, the first line of the prompt
  is used.
- **Start** creates a new worktree (branch `task/<title>`) and starts the
  project's default agent there with the prompt. Every Start makes a new
  worktree. If the start fails, the card stays in Backlog with the reason;
  Start retries.
- A started card follows its session: running → Running, waiting for input or
  permission → Needs you, idle or ended → Review. Click it to open the session.
- **Move to** moves a card by hand. Moving to Done or Backlog stops it
  following its session; Running, Needs you and Review keep following. A card
  that was never started can only move to Backlog or Done.

The board is saved per project in the plugin's storage and survives restarts.
If Alas quits while a card is starting, the card can stay in Backlog even
though its worktree and agent were created; starting it again makes a second
worktree.
