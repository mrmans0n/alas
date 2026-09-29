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
| `agents[].model_catalog.models` | `{id, name}` pairs the agent advertised, as Alas's model picker lists them (Cursor thinking variants collapse to one entry per base model). Present only for `known` and `stale`. Pass an `id` as `session_new`'s `model`. |

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

## Choosing the child's model

`session_new` and `alas session new` take two optional selectors:

| MCP | CLI | Value |
|---|---|---|
| `model` | `--model <id>` | A model id from that agent's `model_catalog.models`. |
| `reasoning` | `--reasoning <value>` | A reasoning level the agent offers for that model (for example `low`, `medium`, `high`). |

Ids belong to the chosen agent. A Claude model id is not valid for Codex, and
Alas never translates one into the other. Omit both to keep today's behavior:
the child starts on the agent's default model and reasoning.

Alas checks a selection twice:

1. **At `session_new`.** The request fails, and no child is created, when a
   live session of the agent on the same host (this Mac, or the project's SSH
   host) advertised a model list during this app run and the model is not on
   it, when such a session advertised no models, or when `reasoning` is
   requested for an agent whose thinking control is not a config option (pi,
   whose thinking is a mode). Anything not confirmed on that host, such as a
   `stale` or `not_loaded` catalog, does not reject here; the live check
   decides.
2. **Before the first prompt.** Alas starts the child's session, checks the
   selection against the models and options the agent advertised for that
   session, and sends `session/set_model` or `session/set_config_option`. The
   initial prompt is queued only after the agent acknowledges every change.
   Reasoning is checked after the model is set, because an agent can offer
   different levels per model (Claude offers no effort setting for `haiku`).

If the live check or the agent rejects the selection, the child is marked
`failed` with the reason, its prompt is never sent, and the parent receives
the usual failure notification. Alas never falls back to the default model.

Reasoning is supported only where the agent exposes a reasoning config option
(Claude `effort`, Codex `reasoning_effort`, and others that advertise a
`thought_level` option). Agents that encode thinking as a mode (pi) or as
model-id variants (Cursor) reject `reasoning`. Cursor's catalog lists one entry
per base model, so its thinking variants cannot be selected by id.

The selection is stored with the delegation. A child waiting for a new
worktree, or interrupted by an app restart before its first prompt, applies
it again before that prompt, or fails visibly if the agent no longer offers
it. Messages sent to such a child with `session_send` while it starts are
held until its first prompt is queued, so the task prompt always runs first
and on the selected model. If the child fails instead, the held messages are
discarded rather than delivered. After that the model is part of the
child's session like any model picked in the composer: it is restored when the
session is reopened, and the user can change it.

## Example

```sh
$ alas agent list | jq -r '.agents[] | select(.available) | .id'
claude
codex
$ alas agent list | jq -r '.agents[] | select(.id == "codex") | .model_catalog.models[].id'
gpt-5.5
…
$ alas session new --agent codex --model gpt-5.5 --reasoning high --prompt "Review the parser changes"
```

## Disabling native subagents

Some agents can start their own subagents. **Settings → Agents → (agent) →
Disable native subagents** removes that tool so the agent delegates through
Alas child sessions instead. The option is off by default and is available
only where Alas has verified a control:

| Agent | Effect |
|---|---|
| Claude | Removes the `Agent`/`Task` and `Workflow` tools, plus `SendMessage` and `ListAgents`, which reach other Claude Code sessions on this Mac, from the model's tool list. `TaskStop` is not affected. |
| Codex | Turns off Codex multi-agent tools (`spawn_agent` and related) through `CODEX_CONFIG`. Any `CODEX_CONFIG` you already set is merged, not replaced; one Alas cannot merge safely (invalid JSON, a non-object `agents`/`features`, or a dotted key that overlaps these settings) fails the launch with an error. Local sessions only: a remote Codex session with the option on fails to start. |
| OpenCode | Removes the `task` tool from every OpenCode agent through `OPENCODE_CONFIG_CONTENT`, and checks every agent's effective permissions before each launch (see below). Any `OPENCODE_CONFIG_CONTENT` you already set is merged with its key order kept, not replaced; one Alas cannot parse fails the launch with an error. Local sessions only. |
| OMP | Starts `omp acp` with a launch-only settings overlay (`--config`) that sets `task.maxRecursionDepth` to 0. This removes the `task` and `hub` tools from the model's tool list, and eval's `agent()` and `workpool()` fail with "Cannot spawn another agent at task depth 0". Eval otherwise works. The overlay is merged over your `~/.omp` and project settings, which Alas does not change, so other settings and extensions keep working. Local sessions only: a remote OMP session with the option on fails to start. |
| Pi | Unavailable. Pi has no built-in subagent tool; extensions may add one, and Alas does not disable extensions. |
| Cursor, Gemini, Copilot | Unavailable until a control is verified. |
| Custom agents | Unavailable. |

When it applies:

- A session keeps the setting it was created with, including forks and
  imported agent sessions. Reconnects and restores reapply it. Changing the
  setting affects only sessions created afterwards, and subagents that are
  already running are not stopped.
- Alas checks the adapter before sending any session request. If it does not
  identify itself as `@agentclientprotocol/claude-agent-acp` 0.81.2 or later
  (Claude), `@agentclientprotocol/codex-acp` 1.13.1 or later (Codex),
  `OpenCode` 1.18.33 or later, or `oh-my-pi` 18.2.11 or later (OMP), the
  session fails to start instead of running unenforced.
- The OMP overlay is a single owner-only file,
  `~/Library/Application Support/Alas/acp-launch-overlays/omp-native-subagents-off.yml`.
  Alas rewrites it before every launch that uses it, including reconnects and
  restores, and passes it on the command line; sessions with the option off
  are launched without it. OMP reads the file again while a session runs (for
  example when eval calls `agent()`), so Alas keeps it in place instead of
  deleting it after launch. If it cannot be written, the session fails to
  start.
- The session's first prompt tells the agent its native subagent tool is off
  and points it at `session_new` (or `alas session new`). If Alas tools are
  turned off (**Expose Alas tools to agents**), the agent is told it cannot
  delegate at all.

### Delegated Claude children

A Claude session delegated by a parent never gets `SendMessage` or
`ListAgents`, whether or not **Disable native subagents** is on. Those tools
list and message other Claude Code sessions on this Mac, outside the
parent/child sessions Alas authorizes, so a child that used them to report
would reach unrelated sessions and its parent would never hear back. Alas
sends the same `disallowedTools` on every `session/new`, `session/load`,
`session/resume`, and `session/fork`, so reconnects and restores keep it. This
does not check the adapter version: an older adapter that ignores the option
still starts the child. When Alas tools are exposed, every delegated child, of
any agent, is told to report only with the `alas` server's `session_send` tool
(or `alas session send <parent-session-id> <prompt>` for CLI-only agents such
as Pi) and not with any other messaging or agent tool.

### OpenCode permission precedence

OpenCode hides `task` from an agent when the last permission rule that matches
it is a blanket `deny`. Rules are evaluated in the order their keys appear, and
agent-specific rules come after top-level ones. Alas's
`OPENCODE_CONFIG_CONTENT` loads after your global and project configuration
(including `.opencode/` agents), but before managed configuration
(`/Library/Application Support/opencode/opencode.json` and the
`ai.opencode.managed` MDM profile), legacy `mode` entries, and
`OPENCODE_PERMISSION`.

So on every launch and reconnect, Alas runs `opencode agent list` with the
session's environment and directory and reads each agent's effective rules:

1. With a top-level `permission.task` deny added, every agent that drops
   `task` is fine as is.
2. Agents that still keep `task` (usually an agent-specific allow in your own
   configuration) get an agent-specific deny, and the check runs again.
3. If any agent still keeps `task`, the session fails to start and names the
   agents. This happens when managed configuration, `OPENCODE_PERMISSION`, a
   legacy `mode` entry, or a permission block that lists `"*"` after `"task"`
   re-enables it. Remove that override or turn the option off.

Every agent is checked, not only the one the session starts with, so switching
agents (modes) during the session cannot bring `task` back. A per-subagent
rule such as `"task": {"general": "deny"}` only narrows which subagents `task`
offers; it does not count. A running OpenCode process computes each agent's
rules once, when it loads the project, and does not reread configuration files
afterwards. Edits made after that take effect, and are checked, when OpenCode
next starts. A reconnect that reattaches to a still-running adapter keeps the
rules that were checked at its launch. A subagent you invoke yourself
(for example an `@general` mention) still runs.

This is not a sandbox: shell commands and extensions can still start other
agents or processes. For OMP, that includes extension tools that spawn agents
themselves and running `omp` from the shell.

Delegated children are leaves in every case. Their MCP discovery does not list
`session_new`, and Alas still rejects a direct `session_new` call from a child.
