# Plugin API v12

> Message reference. The runtime, limits and the rest of the manifest are in
> [api-v4.md](api-v4.md), and APIs 5 to 11 in the files beside it; everything
> there still applies.

API 12 is still being built: this Alas loads plugins with `"api": 4` to `11`,
and the features below need `"api": 12`. A manifest for an older API that uses
them is refused.

## Usage history

Alas records every finished agent turn, in every project: who ran it, when,
how it ended, the tokens it used and what it cost. It also records each
provider usage limit that stopped a session. A plugin with `usage.read` reads
that history.

```json
{ "api": 12, "capabilities": ["usage.read"], "events": ["turn.finished"] }
```

### The `usage.read` capability

The approval sheet shows *Read your agents' token usage, cost and usage-limit
history across all projects*. Requests read the plugin's own project by
default, and every project with `"scope": "all"`; the capability covers both,
so the sheet names the wider one. There is no separate grant for `all`: usage
numbers carry no code, prompts or replies, only session and worktree ids,
agent ids, model names, times, token counts and cost.

### What a turn is

```json
{
  "id": 42,
  "session": "8f0c…",
  "project": "p-1", "worktree": "w-3",
  "agent": "claude", "model": "claude-opus-4",
  "startedAt": 1767000000000, "endedAt": 1767000042000,
  "result": "completed",
  "tokens": { "total": 5120, "input": 1200, "cachedInput": 3600, "cachedWrite": 0, "output": 300, "reasoningOutput": 20 },
  "cost": { "amount": 0.031, "currency": "USD" }
}
```

- Times are epoch milliseconds. `startedAt` is when the prompt was sent,
  `endedAt` when Alas saw the turn end; `endedAt` is never before `startedAt`.
- `result` is `completed`, `failed`, `cancelled` or `limited` (stopped by a
  usage limit).
- `tokens` is the turn's own usage as the agent reported it, or absent when it
  reported none. When the agent reports only per-model counts, they are
  summed. Turns that fail or are cancelled before the agent answers have none.
- `cost` is what the turn added to the session's cost: the growth of the
  cumulative cost the agent reports since the session's previous turn that
  had one. It is absent when no cost update arrived during the turn (often a
  failed or cancelled one), and then the next turn that sees an update is
  given all the growth since. It is also absent when the currency changed. If
  the agent restarts its count, the first turn after it counts the whole new
  total. The first cost-bearing turn recorded for a session has no per-turn
  cost, since its total may include turns from before Alas recorded them; it
  becomes the baseline for the next. The same holds once the session's earlier
  turns have passed the retention.
- `model` is the model that answered when the agent named exactly one, and
  otherwise the session's selected model, if any.
- `project` and `worktree` are absent for sessions of a multi-project
  workspace; only `"scope": "all"` returns those.
- `id` grows with each recorded turn.

Alas keeps 400 days of history.

### `usage/turns`

```json
{ "jsonrpc": "2.0", "id": 7, "method": "usage/turns",
  "params": { "since": 1767000000000, "until": 1767600000000, "limit": 200, "scope": "project" } }
```

→ `{ "turns": [ … ], "truncated": true, "next": { "before": 1767400000000, "beforeId": 40 } }`

- Turns whose `endedAt` is at or after `since` and before `until` (absent: no
  end), newest first.
- `limit` is 1 to 1000, 200 when absent. `truncated` is true when older turns
  in the window were left out. Then `next` is present: ask again with the same
  params and `"cursor"` set to it, and the page continues right after the last
  turn you got, even among turns that ended in the same millisecond.
- `scope` is `project` (the default) or `all`.
- The answer comes in a later delivery and counts towards the 4 requests in
  flight.

### `usage/limits`

Same params, `cursor` included; `since` and `until` apply to `detectedAt`.

→ `{ "limits": [ { "session", "project", "worktree", "agent", "detectedAt", "resetsAt", "resetSource" } ], "truncated": false }`, with `next` when truncated.

One entry per limit episode, from its first detection. A session that hits
the same limit again keeps its entry, with the latest reset time. `resetsAt`
is absent when the reset time is not known; `resetSource` is `structured`
(the agent said), `parsed` (read from its message) or `unknown`.

### `turn.finished`

```json
{ "jsonrpc": "2.0", "method": "turn/finished",
  "params": { "session": "8f0c…", "worktree": "w-3", "turn": { … } } }
```

Sent after each turn of the plugin's project is recorded, with the turn as
`usage/turns` returns it. It needs `usage.read`. Turns of other projects, and
of multi-project workspaces, are not sent; read them with `"scope": "all"`.

### Errors

| Code | When |
|------|------|
| `-32601` | The manifest's `api` is below 12 |
| `-32001` | `usage.read` is not granted |
| `-32602` | `since` missing, `limit` outside 1 to 1000, or an unknown `scope` |
| `-32003` | Alas could not open or read its usage history |
