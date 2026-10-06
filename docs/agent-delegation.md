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

Only ACP-capable agents are listed: the built-in chat agents and agents
installed from the ACP Registry in Settings → Agents (ids `registry-<id>`).
Custom terminal agents cannot be delegated to and are omitted. Alas never
fabricates model ids. The catalog comes from what agents reported on earlier
connections, and the agent stays the authority when a session starts.

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
   An agent that publishes the new model's levels only after acknowledging
   the switch gets a few seconds to do so before the reasoning is rejected.

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
and on the selected model. The same holds for the child's tab: a prompt typed
there while the selection is being applied waits in the queue and runs after
the task prompt, and a tab restored at launch cannot send anything before the
selection is re-verified. If the child fails instead, the held messages are
discarded rather than delivered, and a message sent after the failure is
refused, even by another Alas instance sharing the same profile. After that the model is part of the
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
| Claude | Removes the `Agent`/`Task` and `Workflow` tools, plus `SendMessage` and `ListAgents`, which reach other Claude Code sessions on the same host (the remote machine for an SSH session), from the model's tool list. `TaskStop` is not affected. |
| Codex | Turns off Codex multi-agent tools (`spawn_agent` and related) through `CODEX_CONFIG`. Any `CODEX_CONFIG` you already set is merged, not replaced; one Alas cannot merge safely (invalid JSON, a non-object `agents`/`features`, or a dotted key that overlaps these settings) fails the launch with an error. Local sessions only: a remote Codex session with the option on fails to start. |
| OpenCode | Removes the `task` tool from every OpenCode agent through `OPENCODE_CONFIG_CONTENT`, and checks every agent's effective permissions before each launch (see below). Any `OPENCODE_CONFIG_CONTENT` you already set is merged with its key order kept, not replaced; one Alas cannot parse fails the launch with an error. Local sessions only. OpenCode 1.x only; on OpenCode 2 the session fails to start with this option on. |
| OMP | Starts `omp acp` with a launch-only settings overlay (`--config`) that sets `task.maxRecursionDepth` to 0. This removes the `task` and `hub` tools from the model's tool list, and eval's `agent()` and `workpool()` fail with "Cannot spawn another agent at task depth 0". Eval otherwise works. The overlay is merged over your `~/.omp` and project settings, which Alas does not change, so other settings and extensions keep working. Local sessions only: a remote OMP session with the option on fails to start. |
| Pi | Pi has no built-in subagent tool; extensions add them. Removes the tools of known Pi subagent extensions (`subagent`, `bg_wait`, and `subagent_supervisor` from `pi-subagents`) by starting Pi through an Alas wrapper that adds `--exclude-tools` (see below). Tools from other extensions are not affected. Your Pi settings and any `PI_ACP_PI_COMMAND` you set are kept. Local sessions only: a remote Pi session with the option on fails to start. |
| Antigravity | Sends `_meta.agy.disabledTools: ["start_subagent"]` on every session request, which removes `invoke_subagent`, `define_subagent`, `manage_subagents`, and `send_message` from the model's tool list. Your Antigravity settings are not changed. Requires `antigravity-acp` 1.3.0 or later. |
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
  `OpenCode` 1.18.33 or later and below 2.0, `oh-my-pi` 18.2.11 or later (OMP), or `pi-acp`
  0.0.34 or later (Pi), the session fails to start instead of running
  unenforced.
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

### Pi subagent extensions

`pi-acp` starts Pi as `pi --mode rpc --no-themes [--session <file>]` for every
new and loaded session, and has no way to pass other arguments. Its one lever
is `PI_ACP_PI_COMMAND`, the command it runs instead of `pi`. With the option
on, Alas sets it to an owner-only wrapper,
`~/Library/Application Support/Alas/acp-launch-overlays/pi-native-subagents-off.sh`
(inside the instance's own folder for an isolated `ALAS_APP_SUPPORT_DIR`
instance). The wrapper runs the Pi command with every argument `pi-acp` passed,
plus `--exclude-tools` with every tool in Alas's registry of known subagent
extensions:

| Extension | Verified versions | Excluded tools |
|---|---|---|
| `pi-subagents` (`npm:pi-subagents` or its GitHub source) | 0.68.x | `subagent`, `bg_wait`, `subagent_supervisor` |

The tools are excluded whatever version is installed. Settings counts the
extension as covered only when the installed version (the `version` in its
`package.json` under Pi's `npm/node_modules/` or `git/` folder) is verified.
Any other version, or one Alas cannot read, shows as *pi-subagents
&lt;version&gt; not verified*. To verify a new release, capture its model
request with and without the wrapper (see the #1620 section of
`docs/research/2026-09-25-bb-cross-harness-delegation-research.md`), then widen
`verifiedVersions` or add its new tools in `ACPPiSubagentExtensions.known`.

- **Your own command is kept.** If `PI_ACP_PI_COMMAND` is already set (in the
  agent's environment or Alas's), the wrapper runs that command instead of
  `pi`, with the exclusion appended. Alas cannot see what that command does:
  if it appends its own `--exclude-tools`, Pi keeps the last one and Alas's
  list is lost. Settings therefore reports a custom `PI_ACP_PI_COMMAND` as
  not enforced.
- **Every launch, fresh or resumed.** Alas rewrites the wrapper before every
  launch that uses it, including reconnects and restores, and never deletes it
  while Alas runs, because `pi-acp` runs it again for every loaded session. Pi
  applies the exclusion to tools an extension registers later, too.
- **Failures stop the launch.** If the wrapper cannot be written, or the Pi
  command it runs (your `PI_ACP_PI_COMMAND`, or `pi` on the launch `PATH`)
  cannot be found, the session fails to start with an error instead of running
  unenforced.
- **Settings shows what it covers.** Alas reads, without changing, the
  `packages` and `extensions` in your Pi settings (`~/.pi/agent/settings.json`,
  or `$PI_CODING_AGENT_DIR/settings.json`), the files in its `extensions`
  folder, and the same in the `.pi` folder of each local project, its
  worktrees, and each local workspace checkout. Extensions your
  settings disable (`-path` or `!pattern` entries) are skipped. It reports one of:
  - *Covers the installed …*: every installed extension is recognized, and the
    known subagent extensions among them are covered.
  - *Nothing to remove yet*: no known subagent extension is installed, and
    nothing unrecognized is.
  - *Not enforced for extensions or commands Alas does not recognize*: names
    the packages, local extensions, and custom `PI_ACP_PI_COMMAND` Alas does
    not know. A subagent tool one of them adds stays available.
    `pi-mcp-adapter` and Alas's own `alas-notify.ts` hook (while it carries
    Alas's marker) count as recognized; project extensions are listed even if
    Pi has not been told to trust that project.

The option makes no claim about other extensions, extensions passed with `-e`
by your own command, or Pi started from a shell.

### Delegated Claude children

A Claude session delegated by a parent never gets `SendMessage` or
`ListAgents`, whether or not **Disable native subagents** is on. Those tools
list and message other Claude Code sessions on the host the adapter runs on, outside the
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

OpenCode 2 removed `opencode agent list` and renamed the `task` permission to
`subagent`, so Alas cannot verify the policy there yet. With "Disable native
subagents" on, an OpenCode 2 session fails to start and says so.

This is not a sandbox: shell commands and extensions can still start other
agents or processes. For OMP, that includes extension tools that spawn agents
themselves and running `omp` from the shell.

Delegated children are leaves in every case. Their MCP discovery does not list
`session_new`, and Alas still rejects a direct `session_new` call from a child.

## Child roles

`session_new` accepts an optional `role`, such as `planner`, `implementer`, or
`reviewer`. The CLI equivalent is `alas session new --role reviewer --prompt
"Review the parser changes"`. Alas stores the role with the delegation, shows
it on the child row and in `session_list`, and includes it in the child's
initial task context, including when startup resumes after an app restart.
Roles describe the task; they do not change the child's permissions or tools.

## Messages between parent and child

`session_send` (or `alas session send`) reaches only a direct parent or a
direct child. Alas queues the message as a prompt in the target session.

Child reports and wake notices received within 250 ms share one parent prompt.
Reports arriving while the parent is busy join its pending child-results
prompt. Each result keeps its labelled child section and delivery identity,
so reopening a session does not deliver the same result again. Informational
notices remain transcript notices and do not wake the parent. A result that
has already started sending, failed, or needs recovery is kept intact.

A child's message to its parent starts with one header line, so the parent
agent can tell a report from its user's prompt:

```text
[alas system] Report from delegated session <child-session-id> (<agent-id>, worktree <name>) via session_send:
<the child's message>
```

The worktree clause is omitted when the worktree is unknown. In the parent's
transcript the report renders as a full-width card, not a user bubble, headed
**Report from \<agent\> child · \<first 8 characters of the session id\>**.

The prompts Alas itself sends a parent about its child start with
`[alas system] Delegated session …` instead. They render as the same card, but
headed as Alas's notice, not as the child's report:

| Prompt | Card header |
|---|---|
| The child has waited on a permission, question, or plan prompt past the escalation delay | **Alas · \<agent\> child \<id\> needs a human decision** |
| The child's turn ended without a `session_send` report | **Alas · \<agent\> child \<id\> finished without a result** |
| The child's turn or the child itself failed | **Alas · \<agent\> child \<id\> failed** |

A child turn that ended after a report, or that the user cancelled, does not
wake the parent. It appears in the parent's transcript as a one-line notice,
for example `Delegated session <id> (<agent-id>) had its turn cancelled by the
user.`

A parent's message to its child is delivered unchanged and rendered as the
same kind of card headed **Delegated prompt**, as is the child's initial task
prompt.

A delegated prompt that arrives while the target is mid-turn waits for the
turn to end, but it is not listed in the target's **Up next** queue and does
not count toward its queue badge: it is not the user's to edit, reorder, or
remove, and **Clear all** leaves it in place. If sending one fails, it appears in the queue with its error so you can retry or remove it.

## Reading, waiting on, and stopping sessions

Four more tools act on the same direct edges. Each returns one JSON line.

| MCP tool | CLI | Who may call it | What it does |
|---|---|---|---|
| `session_read` | `alas session read <id> [--offset <n>] [--limit <n>] [--max-chars <n>]` | parent or child, on the other; any session, on a session the user attached to it | One page of the transcript |
| `session_search` | `alas session search <query> [--limit <n>]` | any session | Case-insensitive text search across its direct parent and children |
| `session_wait` | `alas session wait <id>... [--timeout-ms <n>]` | parent, on its children | Blocks until every listed child settles, or the timeout passes |
| `session_interrupt` | `alas session interrupt <id>` | parent, on its children | Cancels the child's running turn, like **Stop** |

Siblings, sessions in other projects, and sessions outside a delegation are
not reachable, so a child can read its parent but not another child of that
parent. The one exception is a session the user attached to one of the
caller's prompts, by `@`-mentioning it in the composer or dragging its badge
from the sidebar onto the composer: `session_read` can read it as long as it
belongs to the caller's project. The prompt itself carries the session's id
and its latest entries, so agents without the Alas MCP server still get that
context. Delegated children's MCP discovery leaves out `session_wait` and
`session_interrupt`, as it leaves out `session_new`, and Alas rejects them from
a child anyway.

**Transcripts.** A transcript is a list of entries with an `index`, a `role`
(`user`, `agent`, `tool`, or `system`), and `text`. Tool calls and file edits
appear as one-line summaries such as `Bash [completed]`; their output is not
included. Thoughts and plans are left out. Without `--offset`, `session_read`
returns the latest entries; otherwise it reads forward from that index. The
reply's `end` is the offset to continue from, and `total` is the entry count.
While the session is running, `end` stops on its last entry, which may still
be growing, so the next page reads that entry again in full.
`--limit` (1 to 100, default 20) caps entries and `--max-chars` (1 to 100,000,
default 8,000) caps their combined text. When the first entry alone is over the
budget it is cut and marked `"truncated": true`. Search matches carry the
session id, the entry index (a valid `--offset`), and a snippet. An archived
session's transcript is not readable.

**Waiting.** A child is settled when it is not starting, has no turn running,
and has no prompt queued or undelivered, so waiting right after `session_send`
does not return before that prompt has run. A child blocked on a permission,
question, or plan prompt is also settled, with state `awaiting_input`. A child
with no live session in this Alas instance is judged by its stored queue, and
stays unsettled when that store cannot be reached. Every prompt a parent sends
goes through that queue, but a turn the user starts from the child's tab in
another Alas instance does not, so a wait cannot see it. The
timeout is 1 to 20,000 ms (default 20,000), below the CLI's 30-second socket
limit; call again while `timed_out` is `true`. Each session in the reply has
its `state`, `settled`, the tail of its latest agent message as
`last_agent_text`, and any `failure`. Waiting does not replace the outcome
prompts above: a child that finishes without reporting still wakes the parent.

**Interrupting.** `cancel_requested` is `false` when the child had nothing
running, or when another Alas instance holds its lease and this one cannot stop
it. Cancelling a turn cancels any permission request it was blocked on.
No session tool can approve a permission request, the caller's own or another
session's: only the user can.

## Across an app restart

A delegated child's agent runs in an ACP broker that outlives Alas, so quitting
Alas does not stop a child mid-task. Its `alas mcp` server and `alas` CLI reach
Alas through a per-session link, `sock-acp-<session-id>`, in the socket
directory (`/tmp/alas-<uid>`, or the isolated profile's runtime directory),
never through the PID-named socket itself. Every time a session attaches, the
attaching instance points that link at its own socket. Only the instance that
holds the session's lease attaches it, so a second instance on the same profile
cannot take over another instance's link.

On launch, Alas re-attaches every ready child whose queue still holds a prompt
the parent is waiting on: one that was running when Alas quit, or one that had
not been sent yet. The prompt is resent under its original broker operation, so
the broker returns the turn that is still running, or the one that finished
while Alas was down, rather than starting a new one. Then:

- a `session_send` the child makes after the relaunch reaches the parent;
- when the turn ends, the parent gets the usual outcome: a notice if the child
  reported during the turn, including before the quit, and otherwise a "finished
  without a result" or failure prompt;
- if the broker did not survive (for example, after a reboot) or the child
  cannot be reconnected, the child is marked `failed` and the parent is told
  that its turn was lost.

A message the child tried to send while Alas was down was never queued. The
child sees the error, and the parent learns about the turn from its outcome.

Limits: children started by builds before this change still use the old
PID-named socket and cannot reach Alas until their adapter restarts. The
built-in MCP server's HTTP transport (**Settings → Agents**) runs under the
app, so it does not survive a restart; the default stdio transport does.
