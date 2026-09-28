# Agent delegation

Root ACP sessions can start direct child sessions through the built-in `alas`
MCP server (`session_new`) or the equivalent CLI (`alas session new`). Before
choosing a child agent, call the read-only discovery command:

| Surface | Command |
|---|---|
| MCP | `agent_list`, optional `worktree` |
| CLI | `alas agent list [--worktree <name-or-branch>]` |

Both return the same JSON for the same calling session. The command needs an
originating ACP session (`ALAS_SESSION_ID`, injected into every ACP session);
from a plain terminal it fails with
`session commands require an originating ACP session`.

Availability depends on where the child would run. Without `worktree`, it is
reported for the caller's worktree. When you plan `session_new --worktree X`,
pass the same `worktree` here. A `new_worktree` child checks only that the
agent is enabled and ACP-capable before the worktree exists.

Discovery is read-only. It does not start a session, send a model request,
or move focus. It reads current Settings, the agent install state for the
caller's worktree, and the models agents have already advertised. For a remote
project, it may re-run the same install probe that `session_new` uses.

## Response (version 1)

```json
{
  "version": 1,
  "caller_agent_id": "claude",
  "can_delegate": true,
  "worktree_id": "3f2a…",
  "agents": [
    {
      "id": "claude",
      "display_name": "Claude Code",
      "available": true,
      "availability": "available",
      "model_selection": "supported",
      "model_catalog": {
        "state": "known",
        "models": [
          { "id": "default", "name": "Default (recommended)" },
          { "id": "opus", "name": "Opus" }
        ]
      }
    },
    {
      "id": "gemini",
      "display_name": "Gemini CLI",
      "available": false,
      "availability": "disabled",
      "model_selection": "unknown",
      "model_catalog": { "state": "unavailable", "models": [] }
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `version` | Schema version. Breaking changes bump it. |
| `caller_agent_id` | The agent `session_new` uses when `agent` is omitted. Null if the calling session is no longer live. |
| `can_delegate` | `false` for a delegated child. Children cannot create sessions, whatever `available` says. |
| `worktree_id` | The worktree whose install state `available` reflects. |
| `agents[].id` | Stable agent id. Pass it as `session_new`'s `agent` (`--agent` in the CLI). |
| `agents[].display_name` | Human-readable name. |
| `agents[].available` | `true` only when `availability` is `available`. Only these agents are valid `session_new` targets. |
| `agents[].availability` | `available`, `disabled` (turned off in Settings), `not_installed` (its CLI was not detected where the caller's worktree runs; for a local project Alas re-checks the binary on every call, and an agent installed after Alas's last scan is listed once Settings rescans), or `unknown` (a remote host's install probe has not answered). |
| `agents[].model_selection` | `supported` (the agent has advertised models), `unsupported` (a live session advertised none during this app run), or `unknown` (no live session has reported yet). |
| `agents[].model_catalog.state` | See below. |
| `agents[].model_catalog.models` | `{id, name}` pairs the agent advertised, as Alas's model picker lists them (Cursor thinking variants collapse to one entry per base model). Present only for `known` and `stale`. |

Model catalog states:

| State | Meaning |
|---|---|
| `known` | A live session of this agent advertised these models during this app run. |
| `stale` | Remembered from an earlier run and not re-confirmed since. Treat as a hint. |
| `not_loaded` | Nothing remembered. Open a session with this agent once to populate it. |
| `unsupported` | A live session advertised no model list, and none is remembered. |
| `unavailable` | The agent is not a valid target for this caller (`available` is `false`). |

Only ACP-capable agents are listed. Custom terminal agents cannot be delegated
to and are omitted. Alas never fabricates model ids. The catalog comes from
what agents reported on earlier connections, and the agent stays the authority
when a session starts.

## Example

```sh
$ alas agent list | jq -r '.agents[] | select(.available) | .id'
claude
codex
$ alas session new --agent codex --prompt "Review the parser changes"
```

## Disabling native subagents

Some agents can start their own subagents. **Settings → Agents → (agent) →
Disable native subagents** removes that tool so the agent delegates through
Alas child sessions instead. The option is off by default and is available
only where Alas has verified a control:

| Agent | Effect |
|---|---|
| Claude | Removes the Agent/Task tool from the model's tool list. Other Claude tools that coordinate work, such as SendMessage and Workflow, are not affected. |
| Codex | Turns off Codex multi-agent tools (`spawn_agent` and related) through `CODEX_CONFIG`. Any `CODEX_CONFIG` you already set is merged, not replaced; one Alas cannot merge safely (invalid JSON, a non-object `agents`/`features`, or a dotted key that overlaps these settings) fails the launch with an error. Local sessions only: a remote Codex session with the option on fails to start. |
| Pi | Unavailable. Pi has no built-in subagent tool; extensions may add one, and Alas does not disable extensions. |
| Cursor, Gemini, Copilot, OpenCode, OMP | Unavailable until a control is verified. |
| Custom agents | Unavailable. |

When it applies:

- A session keeps the setting it was created with, including forks and
  imported agent sessions. Reconnects and restores reapply it. Changing the
  setting affects only sessions created afterwards, and subagents that are
  already running are not stopped.
- Alas checks the adapter before sending any session request. If it does not
  identify itself as `@agentclientprotocol/claude-agent-acp` 0.81.2 or later
  (Claude) or `@agentclientprotocol/codex-acp` 1.13.1 or later (Codex), the
  session fails to start instead of running unenforced.
- The session's first prompt tells the agent its native subagent tool is off
  and points it at `session_new` (or `alas session new`). If Alas tools are
  turned off (**Expose Alas tools to agents**), the agent is told it cannot
  delegate at all.

This is not a sandbox: shell commands and extensions can still start other
agents or processes.

Delegated children are leaves in every case. Their MCP discovery does not list
`session_new`, and Alas still rejects a direct `session_new` call from a child.
