# Alas

Alas is the user's macOS workspace app: worktrees, files, reviews, agent
sessions, web previews, Mac apps, worktree VMs, simulators and devices. Drive
it with the `alas` CLI from your shell. In an Alas session the CLI reaches the
app through `$ALAS_SOCKET_PATH` and `$ALAS_SESSION_ID`; in a terminal it finds
the Alas that owns the current directory.

## Every tool

`alas tool list` names every Alas tool, `alas tool schema <name>` prints its
arguments, and `alas tool call <name> '<json-arguments>'` runs it (`-` reads
the JSON from stdin). These are the same tools the built-in Alas MCP server
offers, so use them when those MCP tools are missing. An image in a reply,
such as a screenshot, is saved to a file the output names as `image_path`.
The commands in these guides are shorter forms of the same tools.

## Core commands

- `alas open <path> [path...]` or `alas open <path> --line <n> [--end-line <n>]`
  reveals files to the user.
- `alas notify <body> [--title <title>] [--level info|attention]` posts a macOS
  notification. Use it to reach the user when you are blocked on them.
- `alas wt list | switch <name> | new <branch> [--base <ref>] | delete <name>`
  manages this project's worktrees.
- When an explanation has shape (how parts connect, options compared on
  several dimensions, before/after layouts, or numbers that read better as a
  chart), draw it: a ```` ```visual ```` fenced block of HTML in your reply,
  with an optional title after the tag, renders inline in the user's theme.
  For charts use `<alas-chart type="bar|hbar|line" data='{"labels":[...],"series":[{"name":"...","values":[...]}]}'>`
  rather than hand-drawn SVG; the frame also provides `stats`/`stat`,
  `timeline`, `flow` and `callout` classes and styles tables.
- `alas visual show --title <title> --html-file <path>` shows an HTML visual
  through a tool call instead, for a mockup in a titled card or a question. Add
  `--question <prompt> --option <id>=<label>...` to let the user pick: put
  `data-choice="<id>"` on the matching elements, then end your turn, because
  the answer arrives as the user's next message.

## Routes

Load the guide for each concern the task has. Add a second only when it owns
a separate part of the work.

| Task | Guide |
|---|---|
| Review pane comments and verdicts, opening or checking a pull request, shipping a gg stack | `alas-review` skill, or `alas skill guide review` |
| Delegating to child agent sessions, messaging a parent or child, reading their transcripts | `alas-delegation` skill, or `alas skill guide delegation` |
| The user's web preview tabs | `alas-preview` skill, or `alas skill guide preview` |
| Seeing and operating Mac apps, or running commands in a worktree VM | `alas-computer-use` skill, or `alas skill guide computer` |
| iOS simulators and Android devices | `alas-devices` skill, or `alas skill guide devices` |

## Errors

A failed command prints `alas: <message>` on stderr and exits non-zero. A
message that starts with a code, such as `computer_user_active`, names the
condition; each guide says how to handle its codes. `could not reach Alas`
means the app is not running or this shell cannot reach its socket.
