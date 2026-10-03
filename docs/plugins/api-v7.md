# Plugin API v7

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), API 5's commands, events, settings, web requests,
> timers and panels in [api-v5.md](api-v5.md), and API 6's slots, badges,
> events, requests, processes and files in [api-v6.md](api-v6.md); everything
> there still applies.

API 7 brings plugins into the agent conversation: commands in a message's
"…" menu, slash prompts in the composer that the plugin expands, and context
the plugin adds to every prompt.
[API 8](api-v8.md) adds commands that open a tab, and progress and link nodes.

## The `api` field

Alas loads plugins with `"api": 4` to `7`. Everything below needs `"api": 7`:

- The capability `session.context` and `contributes.prompts`. An older
  manifest that asks for them is refused.
- The `message.menu` slot. An older manifest that names it has it skipped, not
  refused, as an older Alas would.

`alas/activate` carries the manifest's `api`.

## Requests from Alas

Until API 7 every request went from the plugin to Alas. `prompt/expand` and
`context/provide` go the other way: Alas sends a request with a numeric `id`,
and the plugin answers with a response carrying the same `id`, a `result` or
an `error`, as Alas answers the plugin's own requests. Both results are
`{"text": …}`.

```json
{ "jsonrpc": "2.0", "id": 3, "method": "prompt/expand", "params": { "name": "linear", "args": "ENG-123", "session": "7C1…" } }
{ "jsonrpc": "2.0", "id": 3, "result": { "text": "Fix ENG-123: the login button…" } }
```

A response to an id Alas is no longer waiting for is ignored, like any stray
response.

## Message menu

| Slot | Where | Target |
|---|---|---|
| `message.menu` | The "…" menu of a user or agent message in an agent session | `{"kind": "message", "session", "text"}` |

`text` is the message's Markdown, cut to 32 KiB on a character boundary.
`session` is the session id of `workspace/snapshot`. The items appear after
Alas's own, one flat group, in plugin order.

```json
{ "jsonrpc": "2.0", "method": "command/run",
  "params": { "command": "file-issue", "target": { "kind": "message", "session": "7C1…", "text": "The build fails because…" } } }
```

## Slash prompts

```json
"contributes": {
  "prompts": [
    { "name": "linear", "description": "Work on a Linear issue" },
    { "name": "review-checklist" }
  ]
}
```

- At most 16 prompts. `name` is 1 to 32 lowercase letters, digits and dashes,
  starting with a letter or digit; `description`, optional, is at most 200
  characters and shows in the composer's slash picker.
- The composer offers `/name` next to the agent's own commands while the
  plugin runs in the session's project. A name Alas already handles (`/btw`)
  or that an earlier plugin took is skipped. A plugin prompt hides an agent
  command with the same name.
- When the user sends a message that starts with `/name`, it does not go to
  the agent. Alas sends `prompt/expand {name, args, session}`, where `args` is
  the rest of the message, trimmed. The plugin's `text`, 1 byte to 32 KiB and
  not only whitespace, replaces the draft in the composer, so the user reads
  it before sending it. If the user changed the draft in the meantime, it is
  left alone.
- The answer may come in a later delivery, after the plugin's own requests
  such as `http/fetch`, so `/linear ENG-123` can look the issue up. Alas waits
  up to 30 seconds. An error, an empty or oversized `text`, or no answer shows
  the reason in the session and keeps the draft.
- A message with attachments is refused with a reason rather than expanded,
  since the expansion would replace them.

## Context providers

```json
{ "api": 7, "capabilities": ["session.context"] }
```

A plugin granted `session.context` is asked before every prompt an agent
session of the project sends, whoever wrote it:

```json
{ "jsonrpc": "2.0", "id": 4, "method": "context/provide", "params": { "session": "7C1…", "worktree": "wt-3" } }
{ "jsonrpc": "2.0", "id": 4, "result": { "text": "Design doc: …" } }
```

- Alas adds the `text`, up to 16 KiB, to the prompt as a separate block that
  starts "Context from the Alas plugin *name*:". The agent sees it; the
  transcript does not.
- The composer shows a chip naming every plugin that provides context, so it
  is never invisible to the user.
- The answer must come in the same delivery as the request, while
  `handle` runs, so a prompt never waits on the network. Keep what you need
  ready, from a timer or an event, and answer from it. An answer that comes
  later is ignored and the prompt goes without it.
- `{"text": null}`, empty text, or no answer adds nothing. An error or a
  `text` over 16 KiB is skipped, with a warning in the plugin's log.
- A plugin that runs past the per-call time limit stops, as for any call. The
  prompt goes out without its context rather than waiting.

## Capabilities

| Capability | Approval sheet says |
|---|---|
| `session.context` | Add text to every prompt sent to agents in this project |

Slash prompts and the message menu need no capability: they run only when the
user picks them, and the message menu sends only the message the user chose.
