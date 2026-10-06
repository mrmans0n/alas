# bb (getbb.app) Task Delegation — Research Findings & Alas Fit Assessment

- **Date:** 2026-09-25
- **Status:** Research complete and re-verified 2026-09-25 (see Appendix B); no code changes proposed yet
- **Scope:** How bb's cross-harness task delegation works, how it compares to Alas's existing orchestration layer, and what (if anything) is worth adopting.
- **Sources:** [getbb.app](https://getbb.app), [get-bb/bb](https://github.com/get-bb/bb) (MIT, ~3.9k stars, latest release `desktop-v0.43.4`), its repo docs (`docs/system-overview.md`, `docs/provider-bridge-protocol.md`, `packages/templates/src/templates/bb-guide-threads.md`, `bb-guide-overview.md`), the three system-message templates in `packages/templates/src/templates/`, `plugins/provider-claude-code/server.ts`, issue [#3959](https://github.com/get-bb/bb/issues/3959), PR [#4213](https://github.com/get-bb/bb/pull/4213), and the "Building a (Restrained) Software Factory" blog post (Sawyer Hood, 2026-09-17).
- **Alas paths:** all Swift files cited below live under `Alas/Sources/` (orchestration in `Alas/Sources/ACP/Orchestration/`, session code in `Alas/Sources/ACP/Session/`, protocol in `Alas/Sources/ACP/Protocol/`, UI in `Alas/Sources/ACP/UI/`). Line numbers were checked against the tree on 2026-09-25.

## TL;DR

bb's "task delegation" is: any agent thread can spawn child threads — on **any provider/model** — via the `bb` CLI (`bb thread spawn`), which is the surface bb's own agent guides point agents at; the server's HTTP API sits underneath. (An MCP surface for delegation is often described but was **not confirmed** in the public docs or the Claude Code provider source — see Appendix B.) Children can run in a **fresh managed worktree** or on a **remote machine**. The parent gets automatic **outcome notifications** when children finish or block. A per-provider setting can **disable native subagents** ("the checkbox") so agents are forced through bb's delegation instead.

**Alas already has the core of this** — cross-harness delegation via `session_new`/`session_send`, worktree provisioning, durable multi-instance message delivery, and a one-level-deep policy — built on ACP rather than a bespoke provider-bridge protocol. The genuinely valuable gaps are bb's **notification semantics** (child completion, blocker triage) and a **native-subagent preference toggle**. These are extensions to the existing `ACP/Orchestration/` layer, not a new subsystem.

---

## Part 1 — What bb is

bb is an agentic IDE ("the IDE that builds itself") whose pitch is: *if you can do it in the editor, an agent in bb can do it too.* Every surface — desktop app (Electron, macOS arm64 / Linux alpha), web app, `bb` CLI, and HTTP API — is a first-class way to drive the same server. Providers listed on the site: Claude Code, Codex, Cursor, Pi, OpenCode, Grok, Build, oh-my-pi, Hermes Agent, "+5 more"; each bills through the user's own subscription.

Agents inside a thread find bb through environment variables: `BB_CLI` (absolute path to the daemon-managed executable), `BB_PROJECT_ID`, `BB_THREAD_ID`, `BB_ENVIRONMENT_ID`. The overview guide's framing: *"Threads can have a parent-child relationship. The parent coordinates the child and receives lifecycle notifications when it completes, fails, or is interrupted."*

### Architecture (per `docs/system-overview.md`)

| Component | Role |
|---|---|
| **Server** | Central hub. All state in SQLite; HTTP API + WebSocket change notifications. Routes work to hosts. |
| **Host daemon** | Per-machine runtime. Connects to server, provisions workspaces, runs provider processes, posts events back. |
| **App / Mobile** | Web/native UIs for following and steering threads. |
| **CLI (`bb`)** | First-class interface for users *and agents*; same capabilities as the app, scriptable, `--json` everywhere. |
| **Provider bridges** | One JSON-RPC protocol (`@bb/provider-bridge-protocol`) between bb's agent runtime and every provider (Codex, Claude Code, Pi, ACP agents…). "The bridge knows the dialect, the runtime knows the timeline." |

Core data model: **Project** (repo) → **Thread** (unit of work; append-only event stream; standard vs. manager) → **Environment** (workspace bound to a host; managed or unmanaged) → **Host** (enrolled machine). Threads can own child threads for delegation.

### Delegation levels (per the blog post)

1. **Cross-provider sub-threads** — any agent spawns child threads on any provider/model. Parent is notified when a child stops. Recommended sparingly: "for most implementation work, a single agent does better than a swarm." Fan-out pays off when deep thinking is done up front by an expensive model and implementation is delegated to cheaper ones.
2. **Long-lived managers** — persistent threads that accumulate feedback and instructions over time (e.g. a marketplace-submission reviewer, an issue-report triager). "A manager is a skill you can talk to." Threads can be **drag-reparented** onto a manager to hand off work.
3. **Plugin-powered orchestration** — Automations (scheduled wake-ups), SlopCop (GitHub event → spawn thread from a prompt template), Workflows (agents *writing code* that orchestrates other agents, per-file fan-out for migrations).

---

## Part 2 — The delegation mechanism, in detail

### Spawning

```
bb thread spawn --project <id> --prompt "..." [options]
  --parent-thread <id>          Parent thread (may be in another project)
  --parent-self                 Parent to the current thread (BB_THREAD_ID)
  --lifecycle-owner-thread <id>  Archive/delete with this owner
  --provider <id>                Provider override (any enrolled provider)
  --model <model>                Model override
  --reasoning-level <level>      low | medium | high | xhigh | max
  --new-environment worktree     Fresh managed worktree
  --base-branch <branch>          Exact Git ref for the new worktree
  --machine <id-or-name>         Run on a remote machine
  --permission-mode <mode>       accept-edits | auto | full
  --visibility <visible|hidden>  Hidden threads report to parent but stay out of the sidebar
  --send-at <when>               Scheduled dispatch (ISO 8601 or 30s/10m/2h/7d)
```

Notable semantics:

- **Parenting is opt-in**; execution defaults (provider, model, reasoning) resolve from explicit flags → live parent execution → remembered project defaults.
- **Permission modes inherit** from parent, adapted to the child provider's supported modes; nesting never caps permissions; a host-level ceiling still applies.
- **Visibility inherits**: children of hidden threads stay hidden, but still report turns and blockers to the parent.
- **Forking** (`bb thread fork`) copies a thread's timeline up to a turn, for handoffs and retries.

### Lifecycle ownership

`lifecycleOwnerThreadId` is an immutable, creation-time-only relationship (independent of sidebar parenting or forks):

- Archiving an owner recursively archives dependents and stops execution; deletion cascades in one DB statement.
- Assigning only at creation to a live thread prevents cycles, self-ownership, and reassignment during deletion.
- Spawn and fork accept a live owner **across projects, hosts, and environments**.

### Parent notifications (the interesting part)

The server injects system messages into the parent thread, from templates shipped in the repo (all three confirmed present in `packages/templates/src/templates/`):

- **`system-message-child-thread-outcome-batch.md`** — batches child outcomes so the parent gets compact context without being forced to act per child. The template body is literally `[bb system]` followed by a server-rendered `{{updates}}` block; the intent line reads *"Give the parent thread compact outcome context without forcing immediate action for every child thread."*
- **`system-message-child-thread-needs-attention.md`** — "needs help" prompt when a child blocks on a pending interaction; renders `{{threadMention}}` plus `{{blockerSummary}}` and instructs the parent to resolve from context or escalate to the user. Its editing notes say to stay *"focused on parent-thread triage"* and not imply the parent can approve or reject on the user's behalf.
- **`agent-thread-message.md`** — wraps inter-thread messages with sender identity ("[bb message from thread:X]") without begging for unnecessary acknowledgements.

A hidden child still reports turns and blockers to its parent; only source-derived forks stay silent.

### The checkbox: `subagentsDisabled`

Per-provider plugin setting (e.g. `bb plugin config provider-claude-code set subagentsDisabled true`), described as *"Hide Claude Code's native Task tool so agents use bb for delegation."*

- Declared in `plugins/provider-claude-code/server.ts` as a boolean plugin setting (default `false`) and mapped to a provider option `providerSubagentsEnabled: settings.subagentsDisabled !== true`. The same setting name also exists for the Codex provider (`plugins/provider-codex/server.ts`; related report #2706).
- Enforced as a `PreToolUse` hook that denies `Agent`/`Task` calls with: *"bb has disabled Claude Code native subagents; use bb delegation instead."*
- **Known wart (issue #3959, opened 2026-09-20, still open):** the setting denies the call but still ships the tool definitions and agent-type list to the model — ~2,600–2,950 dead tokens per thread (~5–6% of a ~52k fresh-thread baseline). PR #4213 ("Withhold Claude Code subagent tools when provider subagents are disabled") adds the tools to the SDK's `disallowedTools` and keeps the hook as a backstop; it was **still unmerged on 2026-09-25**. The lesson is instructive: **deny hooks should be backstops, not the primary mechanism**.

### Why force bb delegation over native subagents?

Because bb delegation is the *only* path that is:

- **Cross-provider** — native Claude Code subagents are Claude Code subagents; bb children can be any harness/model.
- **Observable** — children render in the same thread timeline, steerable mid-flight, with usage and context telemetry.
- **Uniform** — one lifecycle, one permission ceiling, one notification protocol, regardless of which harness the parent runs on.

---

## Part 3 — What Alas already has

Alas's `ACP/Orchestration/` layer is a *cross-harness delegation system that already exists in production*, with hardening bb doesn't publicly document (multi-instance claims, crash recovery, Darwin-notify wake-ups).

### Mechanism A — Alas-mediated delegation (cross-harness)

| Concern | Alas implementation | Key files |
|---|---|---|
| Spawn / message / list | MCP tools `session_new`, `session_send`, `session_list` + `alas session` CLI | `AlasCLI/crates/alas/src/mcp.rs:215`, `AlasActionService`, `Alas/Sources/App/AlasCLICommandRouter.swift:106` |
| Coordinator | Resolves target agent (any ACP harness), boots child, tracks phases (`creatingWorktree → starting → ready/failed/closed`) | `ACPSessionOrchestrationCoordinator.swift:4` |
| Worktree provisioning | Optionally creates a **fresh git worktree** for the child | `ACPWorktreeSessionBootstrapper.swift:26` |
| Durability | Dedicated SQLite store (`acp-orchestration.sqlite`), claim-based inbox so **multiple Alas instances** cooperate on delivery; stale-claim reclaim; crash/relaunch recovery | `ACPOrchestrationPersistence.swift:3` (`enqueue` at :80, `claimMessage` at :96), `ACPOrchestrationStore.swift`, `AppState.swift:1540` |
| Policy | Same-project only; direct parent↔child messaging only; **delegated sessions cannot spawn grandchildren**; agent must be enabled and ACP-capable | `ACPSessionOrchestrationPolicy.swift:36` (error cases `delegatedSessionCannotCreateChild`, `crossProjectTarget`, `targetIsNotDirectRelative`, `agentUnavailable` at :38–41; `authorizeCreate` at :45, `authorizeSend` at :53) |
| Agent education | First-prompt preamble tells fresh parents they can delegate, and children they must return results via `session_send` | `ACPMCPPromptPreamble.swift:109` |
| UI | Delegated-sessions tree in the Agent tab and sessions popover; children roll up under parents in the sidebar | `ACPSessionsButton.swift:66`, `AgentSidebarRollupBuilder` (`Alas/Sources/Right/AgentSidebarRollup.swift`), `AppState.swift:11788` |

**Verified gap:** the *only* place Alas constructs an `ACPDelegatedMessage` is the `session_send` handler at `ACPSessionOrchestrationCoordinator.swift:299`. Nothing observes a child reaching `idle`/`closed`/`failed` and tells the parent. The coordinator's `startPersistedChild` (:360) marks phases and calls `environment.notifyChanged()` for the UI, but that is a view refresh, not a message to the parent session.

### Mechanism B — native ACP subagents (same-harness)

- `subagent_spawned` / `subagent_state_update` per ACP RFD 1992, normalized across dialects (incl. OpenCode).
- Rendered inline in the parent transcript as collapsible rows with live child transcripts: `ACPSubagentRowView.swift:40`, `ACPSubagentRun.swift:16`, `ACPSession.swift:1829` (`registerSubagent`; `applySubagentState`/`applySubagentUpdate` follow at :1893/:1906; the `.subagentSpawned` update is handled at :584 and :752).
- Capability negotiated per connection: `supportsSubagents` at `ACPConnection.swift:55` (defaults to `false` at :66).
- There is currently **no** `disallowedTools`/`allowedTools` plumbing anywhere in `Alas/Sources` or `AlasCLI`, and Alas sends no `_meta` on `session/new`. A "force Alas delegation" toggle therefore needs per-harness wiring; Appendix C records which harnesses expose a switch and where it would attach.
- Alas already opts into RFD 1992 subagent updates: `ACPClientCapabilities` defaults `subagents` to an empty object (`ACPMessages.swift:55–76`) and `ACPConnection.swift:103` sends it.

### Side-by-side with bb

| Capability | bb | Alas |
|---|---|---|
| Cross-provider children | ✅ | ✅ (any ACP harness) |
| Fresh worktree per child | ✅ managed worktree | ✅ coordinator provisions |
| Parent gets child completion notice | ✅ automatic outcome batches | ❌ **child must explicitly `session_send`** |
| Parent gets blocker triage prompt | ✅ "needs help" injection | ❌ no parent routing of child permission requests |
| Deny native subagents (the checkbox) | ✅ per-provider setting (with the #3959 wart) | ❌ both paths coexist |
| Deep trees / fan-out | ✅ arbitrary nesting | ❌ one level, direct relatives only (deliberate) |
| Multi-instance delivery | — (single server) | ✅ claim-based inbox across instances |
| Remote machines | ✅ enrolled hosts + daemons | ➖ SSH/broker ACP path exists (`ACP/Broker/`), not tied to delegation |
| Scheduled spawns | ✅ `--send-at` | ❌ |
| Persistence / crash recovery | SQLite (server) | ✅ SQLite + recovery, arguably deeper |
| Protocol foundation | bespoke provider-bridge JSON-RPC | ACP (open standard, RFD 1992) |

**Design-philosophy note:** bb needed a bespoke bridge protocol because it wraps providers that don't speak a common agent protocol. Alas rides ACP, which already gives it normalized sessions, subagents, permissions, and terminals across every harness it supports. Adopting bb itself — or its protocol — would be a step backwards.

---

## Part 4 — Recommendations

Ranked by value-to-effort. All are extensions of the existing orchestration layer; none require new infrastructure.

### 1. Child completion notifications (high value, low effort) — *recommended*

**Problem:** Alas children must *remember* to `session_send` their results. A child that finishes and forgets strands the parent (confirmed: `session_send` is the sole producer of delegated messages, see Part 3). bb solves this server-side: when a child stops, the parent gets an outcome batch automatically.

**Sketch:**
- Add a stop/idle observer to delegated children in the coordinator or session runner (`ACPSessionRunner.swift` already routes lifecycle updates).
- On stop with no explicit `session_send` result, synthesize a compact outcome message ("child X finished; last turn summary") and enqueue it to the parent through the **existing durable inbox** (`ACPOrchestrationPersistence.enqueue` at :80 / `claimMessage` at :96).
- Batch like bb does: if several children stop close together, one message, not N. bb's template is deliberately minimal (`[bb system]` + server-rendered body) so the parent isn't nudged into a reply per child.
- Reuse the preamble's phrasing conventions so parents understand it's a system notice, not a reply begging for acknowledgement (bb's `editingNotes` on message templates are a good pattern: sender identity only, no forced ack).

This slots directly into the infrastructure built for cross-instance delivery — the queue, claims, stale-reclaim, and Darwin-notify wake already exist (`AppState.deliverPendingDelegatedMessages` at `AppState.swift:13149`, invoked from the session-recovery paths at :1620/:1654/:1666).

### 2. Subagent preference toggle (medium value, low effort)

**Problem:** Native ACP subagents and Alas-mediated delegation currently coexist with no user control. Some users will want bb's model: *all* delegation observable, cross-harness, and policy-governed — i.e., force everything through Alas.

**Sketch:**
- Add a per-harness (or global) preference: "Prefer Alas-mediated delegation over native subagents."
- When on, gate on the already-negotiated `supportsSubagents` capability (`ACPConnection.swift:55`) and suppress/refuse the native path — via the ACP session's own config surface where one exists (bb's #3959 lesson: **suppress the tool advertisement, don't just deny the call**; a deny hook is a backstop, not the mechanism).
- Tell agents in the preamble that delegation goes through `session_new` (the preamble already carries per-session role text — `ACPMCPPromptPreamble.swift:109`).

### 3. Blocker triage routing (medium value, medium effort)

**Problem:** When a delegated child blocks on a permission request or question, the parent is not involved. bb routes a "needs help" summary to the parent, which can resolve it from context or escalate to the human.

**Sketch:**
- Alas already renders child permission requests in the child's transcript and has the full permission plumbing; what's missing is *parent routing*.
- On a child pending-interaction (permission/question elicitation), enqueue a compact blocker summary to the parent via the same inbox as (1).
- bb's boundary is worth copying: the parent can **advise**, not approve on the user's behalf.

### 4. Deeper trees / fan-out (defer)

Relaxing `ACPSessionOrchestrationPolicy` (one level, direct relatives, no grandchildren) to allow N-level trees or sibling messaging is *a policy change, not new plumbing* — but it should wait until (1)–(3) prove the notification loop. bb's own guidance is that swarms underperform a single agent for most implementation work; the current ceiling may be a feature. If relaxed, bb's lifecycle-ownership rules (immutable, creation-time-only assignment) are the right shape for preventing cycles and deletion races.

### Explicitly not recommended

- **Adopting bb or embedding it** — wrong stack (Node/Electron), bespoke protocol, server/daemon topology that conflicts with Alas's local-first ACP design.
- **Remote-machine delegation, scheduled spawns, plugin-authored workflows** — heavier machinery than Alas's scope; revisit if Alas ever grows remote execution beyond the existing SSH/broker path.
- **Manager threads / drag-reparenting** — the durable delegated-sessions tree plus manual reparenting could approximate this, but it's UI sugar on top of (1); not a driver.

---

## Appendix A — bb internals worth knowing

- **Bridge protocol hygiene** (from `provider-bridge-protocol.md`): undecodable requests must be *answered* with errors, never silently dropped ("a dropped request is an undebuggable 30-second timeout"); stdout must be guarded against stray writes; capability facts are reported by the code that implements them so they can't drift from behavior; handshake facts may only *narrow* a provider's declaration, never widen it.
- **Token economics** (from #3959): a fresh Claude Code thread in bb starts at ~52k tokens; subagent tool definitions + agent-type list cost ~2.6–3k (~5–6%). Relevant to Alas: the MCP prompt preamble and tool surface have the same dead-weight risk when features are disabled — hide, don't deny.
- **Telemetry:** production runs send anonymous counts (app starts, thread counts, message counts); no user/project/message content. `BB_TELEMETRY=false` opts out.
- **Maturity:** active development; core architecture stable, workflows evolving. The `subagentsDisabled` wart has been open since Sep 20, 2026 with a PR (#4213) in flight — delegation is heavily used, but edges are still soft.

## Appendix B — Verification log (2026-09-25)

Trust-but-verify pass over the claims above.

**Confirmed against the Alas tree:** every `file:line` citation in Part 3 and Part 4 resolves to the named symbol. The one-level policy (`delegatedSessionCannotCreateChild`, `crossProjectTarget`, `targetIsNotDirectRelative`) is real. `session_new`/`session_send`/`session_list` are registered in `mcp.rs` at :215–:242 and routed at :678–:710. The preamble's delegated-child wording ("This session was delegated by a parent session: it cannot …") is at `ACPMCPPromptPreamble.swift:118` and :177. `ACPDelegatedMessage` is constructed only at `ACPSessionOrchestrationCoordinator.swift:299` — the basis for Recommendation 1.

**Confirmed against bb:** repo is MIT, ~3.9k stars, latest release `desktop-v0.43.4`. Issue #3959 is open (created 2026-09-20); PR #4213 is open and unmerged. `subagentsDisabled` appears in `plugins/provider-claude-code/server.ts`, `plugins/provider-codex/server.ts`, and DB migrations 0102/0105. All three system-message templates exist with the frontmatter quoted in Part 2. `bb-guide-threads.md` documents `--parent-thread`, `--parent-self`, `--lifecycle-owner-thread`, visibility inheritance, and permission-mode inheritance as described. `bb-guide-overview.md` documents `BB_CLI`/`BB_PROJECT_ID`/`BB_THREAD_ID`/`BB_ENVIRONMENT_ID`.

**Not confirmed (treat as hearsay):**
- That bb exposes delegation over **MCP**. Neither the public site, `system-overview.md`, the agent guides, nor the Claude Code provider's `server.ts` (no `mcpServers` registration) mention it; GitHub code search requires sign-in. The earlier "via CLI, MCP, SDK, or HTTP API" wording was softened accordingly.
- The exact `PreToolUse` hook source and denial string; issue #3959 describes the hook, but the provider file fetched only shows the setting → `providerSubagentsEnabled` mapping.
- The `--send-at`, `--machine`, `--reasoning-level` flag list in Part 2 comes from the earlier pass and was not re-fetched today.

## Appendix C — Phase 0 spike: can each harness hide its native subagent tool? (2026-09-25)

Question per adapter Alas launches (`ACPLaunchCatalog.swift`): does it have native subagents, can they be **hidden from the model** (not merely denied at call time), where would Alas attach the switch, and does it emit RFD 1992 `subagent_spawned` / `subagent_state_update`?

| Adapter | Native subagents | Disable switch | Hidden or denied? | Emits RFD 1992 updates | Confidence |
|---|---|---|---|---|---|
| `claude-agent-acp` | Yes (`Agent`/`Task`) | (i) `session/new` `_meta.claudeCode.options.disallowedTools: ["Agent","Task"]`, merged into SDK `disallowedTools`; (ii) `.claude/settings.json` `permissions.deny: ["Agent"]` (adapter loads user/project/local settings); (iii) `_meta.claudeCode.options.tools` custom list. No CLI flag or env var. | **Hidden**: a bare tool name in deny/`disallowedTools` removes the tool from context; scoped rules like `Agent(Explore)` only block calls | Yes, gated on client `subagents: {}` (Alas sends it) | High |
| `codex-acp` | Yes (`spawn_agent`, `send_input`, `wait_agent`, …; on by default) | `agents.enabled = false` (or `features.multi_agent = false`) in `config.toml`. Adapter forwards overrides only via env `CODEX_CONFIG` JSON, e.g. `{"agents":{"enabled":false}}`, spread into `thread/start` | Docs say "disable multi-agent tools". **The #1588 live probe confirmed omission** of the `multi_agent_v1`/`collaboration` container (Codex 0.157.1) | Yes, gated on `subagents: {}`; otherwise flattened to `tool_call` | High for switch and updates; low for hidden-vs-denied; medium for `CODEX_CONFIG` merge semantics |
| `gemini --acp` | Yes (`invoke_agent` wrapper over `codebase_investigator`, `generalist`, …) | `settings.json` `experimental.enableAgents: false` (master), per-agent `agents.overrides.<name>.enabled`, or `tools.exclude: ["invoke_agent"]` | **Hidden**: excluded tools are dropped from function declarations | **No**: ACP code emits only message/thought/tool_call updates | High |
| `opencode acp` | Yes (`task` tool over `general`/`explore`/`scout` and custom subagent-mode agents) | `permission: {"task": "deny"}` (or per-agent); `tools: {"task": false}` is deprecated sugar for the same. Injectable without touching the project via env `OPENCODE_CONFIG_CONTENT='{"permission":{"task":"deny"}}'`, which loads after `opencode.json` | ~~Denied, not hidden~~ **Superseded by the #1588 live probe: hidden.** On 1.18.33 an effective blanket deny omitted `task` from the captured model request, and a forced call was rejected as an unavailable tool. An agent-specific `permission.task` allow restores it. (Original static reading: the tool registry does not filter by permission; execution throws a denied error.) | Not the RFD spelling: emits `opencode/session/child_update`, opted in via `_meta["opencode/child-session-updates"]`; Alas already re-prefixes it into a synthetic `subagent_spawned` (`ACPOpenCodeChildUpdate.swift`) | High on switch and deny semantics, medium on updates |
| `agent acp` (Cursor) | Yes (`Task` tool over Explore/Bash/Browser and `.cursor/agents/*.md`) | **No first-class toggle.** Permissions config accepts only Shell/Read/Write/WebFetch/Mcp. Options are a `subagentStart` or `preToolUse` hook in `~/.cursor/hooks.json` returning deny, or a rule "never invoke subagents" (reported unreliable) | Runtime-deny only; nothing documented hides `Task` | No RFD updates; emits a custom `cursor/task` notification alongside `tool_call` | High on a/b, medium on c/d (closed source) |
| `copilot --acp` | Yes (`task`, `list_agents`, `read_agent`, `write_agent`; built-in explore/task/code-review/general-purpose; `.github/agents/*.md`) | `--excluded-tools=task,list_agents,read_agent,write_agent` (or `--available-tools` allowlist). Changelog 1.0.64 confirms the flags apply in ACP mode. `--deny-tool` is the wrong lever | **Hidden**: docs say excluded tools "will not be available to the model" | Unknown, leaning no. Changelog 1.0.81 mentions ACP clients receiving subagent IDs, but the ACP reference documents no RFD update names and the source is closed | High on a–c, low on d |
| `pi-acp` | **No** in core; subagents are an example extension or community packages | `--no-extensions`, `--exclude-tools`, `--tools`, or settings `defaultTools`/`extensions`. Caveat: `pi-acp` hardcodes `pi --mode rpc --no-themes` with no arg passthrough; only `PI_ACP_PI_COMMAND` swaps the binary, so a wrapper script is needed | Hidden (tool registration) | No | High |
| `omp acp` | Yes (`task` tool; agents in `~/.omp/agent/agents` or `./.omp/agents`) | `omp acp --tools read,edit,bash,…` omitting `task` (registration allowlist); `tools.approval.task: deny` in settings; `task.maxRecursionDepth`. No documented `task.enabled` key | `--tools` hides; `tools.approval` denies at runtime | No | High on a/d, medium on b/c |

**Consequences for Phase 3 (the toggle):**

- Grouped by how Alas could flip the switch without touching user files:
  - **Env var, one line in `ACPLaunchSpec.extraEnv`:** Codex (`CODEX_CONFIG`), OpenCode (`OPENCODE_CONFIG_CONTENT`; the #1588 live probe showed an effective deny hides `task`, but agent-specific allows restore it).
  - **Launch arguments:** Copilot (`--excluded-tools`, hidden), OMP (`--tools` allowlist, hidden; needs the full built-in list enumerated).
  - **ACP `session/new` `_meta`:** Claude (`claudeCode.options.disallowedTools`, hidden). Alas sends no `_meta` today; small addition.
  - **User settings file on disk:** Gemini (`tools.exclude`). Invasive for Alas to write; document as a manual step.
  - **Wrapper script:** Pi (adapter has no arg passthrough). Low priority since core Pi has no subagents anyway.
  - **No switch:** Cursor. Falls back to preamble instruction plus the existing policy backstop, exactly bb's fallback posture.
- Only Claude and Codex both hide the tool **and** emit RFD 1992 updates. Gemini, Pi, and OMP emit none; Cursor and OpenCode use custom notifications; Copilot is unknown. So gating the toggle's visibility on the negotiated `supportsSubagents` capability, as Part 4 suggested, would hide it on harnesses where it still matters. Gate on the launch-spec capability instead.
- Model the switch as a per-harness capability on the launch spec (`nativeSubagentSwitch: .sessionMeta | .env | .arguments | .userSettings | .none`, plus whether it hides or only denies) rather than a global boolean, so the settings UI can say honestly what will happen on each harness.

**Sources:** claude-agent-acp `src/acp-agent.ts`, `src/native-subagents.ts`, `src/acp-subagents.ts`, README "Subagent sessions"; Claude Code permissions and CLI reference docs; codex-acp README "Runtime options", `src/index.ts`, `src/CodexAcpClient.ts`, `docs/subagent-sessions.md`; Codex config reference and subagents guide on learn.chatgpt.com; gemini-cli `docs/core/subagents.md`, `packages/core/src/tools/tool-registry.ts`, `packages/core/src/agents/registry.ts`, `packages/cli/src/acp/`; RFD 1992 (agent-client-protocol PR 1992); OpenCode docs (agents, permissions, config) and `packages/opencode/src/{tool/registry.ts,session/tools.ts,permission/index.ts,config/config.ts}` on `dev`; Cursor docs (subagents, CLI permissions reference, hooks, CLI ACP) and forum threads 153085/153654/157433; Copilot CLI command reference, custom-agents guide, SDK custom-agents page, ACP server reference, and `github/copilot-cli` changelog (1.0.64, 1.0.81); `badlogic/pi-mono` CLI docs and subagent example, `svkozak/pi-acp` `src/pi-rpc/process.ts`; omp.sh docs (tools, CLI, subagents) and `can1357/oh-my-pi` `packages/coding-agent/src/modes/acp/`.
## Issue #1588: live adapter probe

Live check of the Appendix C claims against the adapters installed on the probe host, for [#1588](https://github.com/mrmans0n/alas/issues/1588) under umbrella [#1596](https://github.com/mrmans0n/alas/issues/1596). The Claude, Codex, OMP, OpenCode, and Cursor results come from an earlier probe whose notes were lost with their branch; they are reproduced here from the comments it left on #1588–#1593. The Pi probe and the version inventory were run on 2026-09-28. No run used a paid provider, installed a package, changed global settings, or wrote to the user's agent directories. Every run used temporary `HOME`/`XDG_*`/agent-config directories and a disposable loopback HTTP server posing as the model provider.

### Evidence types

- **Captured request:** the tool list inside an actual outbound model request, recorded by the loopback server. This is what the model would see.
- **Runtime rejection:** a fake provider deliberately emitted a call to the suppressed tool, and the adapter's response was recorded.
- **Model self-report:** a harmless prompt ("reply `NO_NATIVE_TOOL` if you have no subagent tool") answered by the model. This was the first pass for Claude, Codex, and OMP. It is superseded wherever a captured request exists and is never treated as proof on its own.
- **Static:** reading the installed adapter's shipped source or `--help`.

### Installed versions (2026-09-28)

| Agent in Alas | ACP adapter | Runtime Alas launches by default | Runtime used in the probe |
|---|---|---|---|
| Claude | `@agentclientprotocol/claude-agent-acp` 0.81.2 | Bundled `@anthropic-ai/claude-agent-sdk` 0.3.280 native binary, Claude Code 2.1.280. The adapter uses `CLAUDE_CODE_EXECUTABLE` when set; Alas does not set it | Claude Code 2.1.283 (the `claude` on `PATH`) |
| Codex | `@agentclientprotocol/codex-acp` 1.13.1 | Bundled `@openai/codex` 0.156.1 unless `CODEX_PATH` is set; Alas does not set it | `codex-cli` 0.157.1 via `CODEX_PATH` |
| OMP | `omp acp` (built in) | `@oh-my-pi/pi-coding-agent` **18.2.11** is on `PATH` today | 18.3.1 at probe time; re-run on 18.2.11 for #1590 (see the mapping below) |
| OpenCode | `opencode acp` (built in) | `opencode` 1.18.33 | 1.18.33 |
| Pi | `pi-acp` 0.0.34 | `@earendil-works/pi-coding-agent` 0.85.1 (`pi`) | Same |
| Cursor | `agent acp` | Disabled in Alas; no `agent`/`cursor-agent` binary on `PATH` today | Earlier authenticated run; version not recorded |
| Copilot | `copilot --acp` | Not installed | — |
| Gemini | `gemini --acp` | Not installed (also disabled in Alas) | — |

Both version gaps matter. Claude and Codex were probed on newer runtimes than the adapters bundle and than Alas launches by default. The implementation issues must re-check the default-bundled runtime, or pin the runtime they rely on.

### Matrix

| Adapter / runtime | Control used | Scope | Config precedence | Resume behavior | Evidence |
|---|---|---|---|---|---|
| Claude ACP 0.81.2 / Claude 2.1.283 | `session/new` `_meta.claudeCode.options.disallowedTools: ["Agent","Task"]` | **Model-visible omission** of `Agent`. `ListAgents`, `SendMessage`, `TaskStop`, and `Workflow` **stay in the request**. A bare `Task` tool was absent even in the no-deny control | Omission held against isolated user settings that enabled native agents. Managed-policy precedence not tested | Omitted fresh and after a new-process `session/load`, **when the control is reapplied on load** | Captured request, fresh and resumed; no-deny control showed `Agent` present |
| Codex ACP 1.13.1 / Codex 0.157.1 (`CODEX_PATH`) | `CODEX_CONFIG` = `{"agents":{"enabled":false},"features":{"multi_agent":false,"multi_agent_v2":{"enabled":false}}}` | **Model-visible omission** of the `multi_agent_v1` / `collaboration` tool container, including nested `spawn_agent` | Held against a controlled user config that enabled v2 multi-agent. Merging with an existing `CODEX_CONFIG` and managed policy not tested | Omitted fresh and after a new-process `session/load`. Resume needed an explicit `MODEL_PROVIDER` to stop the adapter falling back to its default provider | Captured request, fresh and resumed |
| OMP 18.3.1 (re-verified on 18.2.11 for #1590, see the mapping below) | Temporary `--config` overlay with `task.maxRecursionDepth: 0` | **Model-visible omission** of `task`. The depth-0 tool list was `read,bash,edit,eval,glob,grep,wait,todo,web_search,write`; depth 2 added `task`. `eval` remains, but its `agent()` helper hits a **runtime denial**: `Cannot spawn another agent at task depth 0; maximum depth is 0.` | Overlay tested in isolation only | Same-process `session/load`/`session/resume` worked. Cross-process `session/load` failed with `ACP session not found`, because of an **`--session-dir` lookup mismatch** (next section). A resumed prompt did not reach the provider, so resumed inventory is unproven | Captured request (fresh), runtime rejection (`agent()`); resume unproven |
| OpenCode 1.18.33 | `OPENCODE_CONFIG_CONTENT` = `{"permission":{"task":"deny"}}` | **Model-visible omission**: nine tools without `task`, a correction to Appendix C's "denied, not hidden". A fake provider that forced an out-of-schema `task` call got `Model tried to call unavailable tool 'task'` and no child request (**unavailable-tool rejection**, not a separate permission gate). Adding `agent.build.permission.task=allow` **restored `task`** (ten tools) despite the global deny | Agent-specific allow overrides the global deny. Managed-config precedence not tested | Same- and cross-process `session/load` recomputed permissions from the launch's config. The same saved session exposed `task` again when relaunched with the allow rule | Captured request, runtime rejection |
| Pi (`pi-acp` 0.0.34 / `pi` 0.85.1) | None through `pi-acp`. `pi --exclude-tools` works, but only if a `PI_ACP_PI_COMMAND` wrapper appends it | Core Pi has **no subagent tool** (baseline request: `read,bash,edit,write`). Subagents come from extensions: `pi-subagents` 0.68.0 adds `subagent`, `bg_wait`, and `subagent_supervisor`. `--exclude-tools subagent` left `bg_wait` and `subagent_supervisor`; excluding all three restored the baseline list | The extension set comes from user or project `settings.json` `packages`, which Alas does not own | Not tested | Captured request (`pi -p` and a `pi-acp` ACP session through a wrapper); static (`pi-acp` spawn arguments) |
| Cursor (`agent acp`) | Temporary plugin with a `sessionStart`/`subagentStart` hook | None established. An authenticated harmless prompt ran, but the `sessionStart` marker **never appeared**, so plugin loading and `subagentStart` stay unestablished | — | — | Negative observation only |
| Copilot | — | Not installed on the probe host | — | — | None |
| Gemini | — | Not installed on the probe host | — | — | None |

### Caveats

- **Claude's "no native delegation" is narrower than it sounds.** `disallowedTools: ["Agent","Task"]` removes `Agent`. `ListAgents`, `SendMessage`, `TaskStop`, and `Workflow` stay model-visible. #1589 has to decide whether its setting covers only `Agent`/`Task` or also workflow-driven delegation, and it must not promise "no native delegation paths" until those tools are checked.
- **Codex resume and provider selection.** A new-process `session/load` needed `MODEL_PROVIDER` set explicitly. Otherwise the adapter fell back to its default provider. Verify launch and resume provider selection separately from suppression.
- **OMP `--session-dir` lookup mismatch (18.3.1).** `session/new` writes the session JSONL into the directory given by `--session-dir`, but ACP `session/list` and `session/load` search the cwd-derived default session directories. A copy of the same JSONL placed in an isolated default directory was listed and loaded by a fresh process. Alas must not relocate user session files as a workaround. Either an upstream version threads the launch directory through ACP lookup, or restart support is not claimed for this adapter/version.
- **OpenCode agent-specific allows defeat a global deny.** `agent.<name>.permission.task = "allow"` in any merged config puts `task` back in the request. A blanket deny can only be reported as enforced after checking the effective config for agent-level overrides.
- **Pi companion tools.** Excluding only `subagent` leaves `bg_wait` and `subagent_supervisor`, which is the same trap as Claude's companion tools. Other Pi subagent packages register different names, so no fixed exclusion list is complete.
- **Capability withdrawal is observation-only.** With no client ACP `subagents` capability **and no disabling config**, Codex still ran a no-op `spawn_agent` child and returned `READY`. Leaving out the capability only changes how updates are reported. It never suppresses the tool.
- **Captured requests are local, not provider-side.** The loopback server shows what the adapter would send. It does not show server-side enforcement on a paid provider, or what managed/enterprise policy would do.
- **Alas integration not exercised under suppression.** An Alas `session_new` did create an OMP child in the same worktree, and `session_list` showed it idle. `session_send` queued a report request, but no transcript result was observed. Alas cannot yet launch a child with any of these controls applied.

### Pi detail

- `pi-acp` (`dist/index.js`, `PiRpcProcess.spawn`) always runs `pi --mode rpc --no-themes [--session <file>]` and passes its environment through. It has no argument passthrough and reads no tool-related `_meta`. Its only relevant knob is `PI_ACP_PI_COMMAND`, which replaces the `pi` executable.
- `pi --help` (0.85.1) offers `--tools`, `--exclude-tools`, `--no-tools`, `--no-builtin-tools`, `--no-extensions`, and `-e`. `settings.json` `defaultTools` applies to built-in tools only ("Extension and SDK custom tools remain enabled"). Per-package `extensions` filters can drop a package's extension entry, but they live in user or project settings. No environment variable excludes tools. `PI_CODING_AGENT_DIR` swaps the whole config directory, which would also drop the user's packages and credentials.
- On the probe host, the user's Pi settings list 18 packages, including `npm:pi-subagents` (0.68.0), plus two local extensions (`alas-notify.ts`, `superset-hooks.ts`). `pi-subagents` is the only one that registers a delegation tool. `pi-superpowers` ships a `subagent-driven-development` skill, not a tool.
- Result: **extension-dependent; unsupported for enforcement.** Pi has no native subagent tool to suppress. Whether a session can delegate depends on the user's extension set, whose tool names Alas cannot enumerate ahead of time. The only working lever is a `PI_ACP_PI_COMMAND` wrapper that appends `--exclude-tools`, and it needs a complete, extension-specific tool list. Alas should report Pi as "depends on installed extensions" and not offer the suppression toggle.

### Reproduction (sanitized)

Every run follows the same shape. Start a loopback server that records each request body and answers with a minimal completion (or a forced tool call for the rejection runs). Point the agent at it through a throwaway provider entry in a temporary config directory. Drive one ACP `initialize` → `session/new` → `session/prompt` (→ new process → `session/load` → `session/prompt`). Diff the `tools` array between control and suppressed runs. `$T` is a fresh temporary directory, `$PORT` is the loopback port, and credentials are dummies. The original Claude, Codex, OMP, and OpenCode scripts were lost with their branch, so those commands are reconstructed from the recorded controls and show the shape of the run, not a transcript. The Pi commands are the ones actually run.

```bash
# Claude: pass the control in session/new params, and again on session/load
#   "_meta": {"claudeCode": {"options": {"disallowedTools": ["Agent", "Task"]}}}
HOME=$T/home CLAUDE_CODE_EXECUTABLE=$(command -v claude) \
  ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT ANTHROPIC_API_KEY=dummy claude-agent-acp

# Codex (resume also needs MODEL_PROVIDER)
HOME=$T/home CODEX_HOME=$T/codex CODEX_PATH=$(command -v codex) MODEL_PROVIDER=probe \
  CODEX_CONFIG='{"model_providers":{"probe":{"name":"probe","base_url":"http://127.0.0.1:'$PORT'/v1","wire_api":"responses"}},"agents":{"enabled":false},"features":{"multi_agent":false,"multi_agent_v2":{"enabled":false}}}' \
  codex-acp

# OMP: overlay config with a loopback provider and task.maxRecursionDepth: 0 (control: 2)
HOME=$T/home omp acp --config $T/omp-overlay.yml --session-dir $T/sessions

# OpenCode: control drops the permission block; override test adds
#   "agent":{"build":{"permission":{"task":"allow"}}}
HOME=$T/home XDG_CONFIG_HOME=$T/xdg/config XDG_DATA_HOME=$T/xdg/data XDG_STATE_HOME=$T/xdg/state \
  OPENCODE_CONFIG_CONTENT='{"provider":{"probe":{...loopback...}},"permission":{"task":"deny"}}' opencode acp

# Pi: models.json in $T/agent defines provider "probe" (api openai-completions, baseUrl loopback)
# Resolve the installed extension with the real HOME, before HOME is overridden below
EXT="$HOME/.pi/agent/npm/node_modules/pi-subagents/index.ts"
cat > $T/pi-wrap.sh <<SH
#!/bin/bash
exec pi "\$@" --no-extensions --no-skills --no-context-files \\
  -e "$EXT" \\
  --exclude-tools subagent,subagent_supervisor,bg_wait
SH
chmod +x $T/pi-wrap.sh
HOME=$T/home PI_CODING_AGENT_DIR=$T/agent PI_OFFLINE=1 PI_TELEMETRY=0 \
  PI_ACP_PI_COMMAND=$T/pi-wrap.sh pi-acp
# Captured tools: read,bash,edit,write
# Without --exclude-tools:      read,bash,edit,write,subagent,bg_wait,subagent_supervisor
# Excluding only subagent:      read,bash,edit,write,bg_wait,subagent_supervisor
```

The Pi wrapper loads the installed extension read-only from its package path with discovery disabled. The run left `~/.pi/agent` unmodified (no file there changed during the run).

### Mapping for implementation issues

- **#1589 (Claude, Codex).** Verified controls: Claude `session/new` (and `session/load`) `_meta.claudeCode.options.disallowedTools = ["Agent","Task"]`, which omits `Agent` but not `ListAgents`/`SendMessage`/`TaskStop`/`Workflow`. Codex `CODEX_CONFIG` with `agents.enabled=false`, `features.multi_agent=false`, and `features.multi_agent_v2.enabled=false`, merged into any existing `CODEX_CONFIG` rather than replacing it. Still open: default bundled runtimes (Claude 2.1.280, Codex 0.156.1), managed-policy precedence, `MODEL_PROVIDER` on resume.
- **#1590 (OMP).** Verified control: a `task.maxRecursionDepth: 0` config overlay, which omits `task` and makes `eval`'s `agent()` fail at runtime. Static check on 18.2.11: `src/tools/index.ts` still gates the `task` tool on `canSpawnAtDepth(task.maxRecursionDepth, taskDepth)`, and `src/tools/hub/messaging.ts` reuses the same gate for peer messaging. The live results are from 18.3.1. Still open: a re-run on the installed build, and a fix or workaround for the `--session-dir` lookup mismatch before any restart claim.
  - **Re-run on 18.2.11 for #1590 (2026-09-29), same method, through the exact argv Alas now emits (`omp [--auto-approve] acp --config <overlay>`, no `--session-dir`).** Captured requests at depth 0 omit `task` and `hub`; the no-overlay control has both. Eval `agent()` (JS and Python) and `workpool()` fail with `Cannot spawn another agent at task depth 0`, and a plain eval cell still runs. The overlay **deep-merges**: an isolated user `config.yml` with `bash.enabled: false` and `task.maxRecursionDepth: 5`, a project `.omp/config.yml` with depth 3, and a user extension tool all kept their effect except the overridden depth. New-process `session/load` and `session/resume` found the session in the default session directory, reached the provider, and kept `task` omitted; a session cwd different from the process cwd did too. The `--session-dir` mismatch does not arise without that flag. OMP re-reads the overlay after startup (eval `agent()` failed with `Config overlay not found` once the file was deleted), so the file must outlive the process. A missing overlay at launch exits with `Config overlay not found`.
- **#1591 (OpenCode).** Verified control: `OPENCODE_CONFIG_CONTENT` with `permission.task = "deny"`. It omits `task`, and a forced call is rejected. Alas must detect agent-specific `permission.task` allows in the effective config and report "not enforced" when one exists. Managed-config precedence is resolved in the #1591 section below.
- **Pi.** Unsupported for enforcement (extension-dependent). Show that state and offer no toggle. A wrapper-based opt-in could follow later if a stable tool-name contract appears.
  - **Superseded by #1620 (2026-09-30).** Alas now ships the wrapper opt-in, bounded to a registry of known subagent extensions (starting with `pi-subagents`), and reports any extension it does not recognize instead of claiming enforcement. See the #1620 section below.
- **Cursor.** Unverified / unsupported. There is no first-class switch, and hook loading was not established (the `sessionStart` marker never appeared). Disabled on the probe host.
- **Copilot (#1592), Gemini (#1593).** Not installed on the probe host. Implementation is deferred until those issues capture tool inventory, exclusion, and resume on an actually installed runtime. For Gemini, that includes preserving any existing system-settings policy.

## Issue #1591: OpenCode permission precedence

Probed on OpenCode 1.18.33 (`opencode acp`, `agentInfo.name` `OpenCode`) with isolated `HOME`/`XDG_*` directories, `OPENCODE_TEST_MANAGED_CONFIG_DIR` pointing the managed directory at a temporary folder, and a loopback OpenAI-compatible provider. Static reading of the v1.18.33 source (`config/config.ts`, `config/managed.ts`, `agent/agent.ts`, `permission/index.ts`, `session/llm/request.ts`) matched every live result.

- **Load order:** well-known remote → global → `OPENCODE_CONFIG` file → project `opencode.json(c)` → `.opencode/` directories (JSON and markdown agents) → **`OPENCODE_CONFIG_CONTENT`** → account/org config → managed directory (`/Library/Application Support/opencode/opencode.json(c)` on macOS) → MDM plist (`/Library/Managed Preferences/[<user>/]ai.opencode.managed.plist`, hardcoded, not testable in isolation) → legacy `mode.*` promoted into `agent.*` → `OPENCODE_PERMISSION` merged into top-level `permission` → legacy `tools` converted beneath `permission`. Layers merge with `mergeDeep`, which updates an existing key in place.
- **Evaluation:** each agent's ruleset is built-in defaults, the agent's built-in extras, top-level `permission`, then `agent.<name>.permission`, flattened in key order. `task` is dropped from the request only when the **last** rule whose permission matches `task` has pattern `*` and action `deny` (`Permission.disabled`). A pattern-scoped deny (`task: {"general": "deny"}`) only filters the subagent list.
- **What the overlay beats (live, `opencode agent list` and captured requests agree):** global and project top-level `task` allows, legacy `tools.task = true` (top-level and agent-level), and agent-specific allows from project JSON or `.opencode/agent/*.md` **when the overlay also denies that agent by name**.
- **What beats the overlay:** managed-directory top-level allows (unless every agent is also denied by name) and managed agent-specific allows, legacy `mode.<name>.permission`, `OPENCODE_PERMISSION`, and any earlier permission block that lists `"*"` after `"task"` (the key keeps its earlier position, so `"*": "allow"` stays last). With per-agent denies, a managed top-level allow still left the hidden `compaction` agent with `task`.
- **Switching and resume:** rulesets are per agent and computed at config load. Switching modes (`build` → custom → `plan`) kept `task` absent when every agent resolved to deny, and a new-process `session/load` recomputed the same result; with only a top-level deny, the same saved session showed `task` again under `build` and the custom agent.
- **Answer to "can the overlay force deny for every agent":** no. It works for global/project sources, not for managed configuration, `mode`, `OPENCODE_PERMISSION`, or the key-order case. Alas therefore asks OpenCode for every agent's effective ruleset (`opencode agent list`, same environment and directory) before each launch, adds agent-specific denies for agents that still keep `task`, re-checks, and fails the launch if any agent still keeps it.

## Issue #1620: Pi subagent extensions through a `pi-acp` command wrapper

Decision: implement the wrapper, with a versioned registry of known subagent extensions. The registry starts with `pi-subagents` (`subagent`, `bg_wait`, `subagent_supervisor`). Alas always excludes every registry tool, whatever detection finds, because Pi ignores excluded names that no extension registered.

- **Lever (static, `pi-acp` 0.0.34 `dist/index.js`).** `PiRpcProcess.spawn` calls `spawn(getPiCommand(process.env.PI_ACP_PI_COMMAND), ["--mode","rpc","--no-themes", ...(sessionPath ? ["--session", file] : [])], {env: process.env})`. On macOS there is no shell and no splitting, so the value is one executable path, spaces allowed, or a bare name resolved on `PATH`. `session/new` and the `session/load` restore path both read the variable. The child's stderr is discarded, so a wrapper that exits early surfaces only as `Internal error: Cannot call write after a stream was destroyed`. Alas therefore resolves the wrapper's target before launch and fails with its own error.
- **Exclusion (static, `pi` 0.85.1).** `--exclude-tools` builds a name set that `AgentSession._refreshToolRegistry` applies on every refresh, to built-in and extension tools, including tools registered later (`pi-subagents` registers `subagent_supervisor` lazily). The last `--exclude-tools` on the command line wins. An unknown `--flag value` becomes an extension flag and, if no extension claims it, an `Unknown option` error, so a Pi without `--exclude-tools` fails instead of running unenforced.
- **Detection (static, `pi` 0.85.1 `package-manager.js`).** Extensions come from global and project `settings.json` `packages` (project first), top-level `extensions` paths, and auto-discovered `<agentDir>/extensions/*` and `<cwd>/.pi/extensions/*`. Project resources load only for trusted projects. The agent directory is `PI_CODING_AGENT_DIR` or `~/.pi/agent`. Alas reads these without writing and counts project resources whether or not the project is trusted.
- **Wrapper.** A fixed, owner-only (0700) script in `Application Support/Alas/acp-launch-overlays/`, rewritten atomically before each launch and never deleted while Alas runs. Its content is constant; the target comes from `ALAS_PI_ACP_PI_TARGET`, which Alas always sets to the user's own `PI_ACP_PI_COMMAND` (agent env first, then inherited) or `pi`. A value equal to the wrapper path is treated as unset.

### Live evidence (2026-09-30)

`pi-acp` 0.0.34 and `pi` 0.85.1, isolated `HOME` and `PI_CODING_AGENT_DIR`, `PI_OFFLINE=1`, and a loopback OpenAI-compatible server that records each request's tool names. The temporary agent directory lists `npm:pi-subagents` in `settings.json`, symlinks the installed `pi-subagents` 0.68.0 package read-only into `npm/node_modules/`, and holds one unrelated local extension that registers `probe_echo`. The wrapper and environment came from `ACPNativeDelegationControls.applyingLaunchControls` in the PR build (a throwaway test wrote them out). Each run is `initialize` → `session/new` → `session/prompt`, then a new `pi-acp` process → `session/load` → `session/prompt`.

| Run | Fresh request tools | After new-process `session/load` |
|---|---|---|
| Control (no wrapper) | `read,bash,edit,write,probe_echo,subagent,bg_wait,subagent_supervisor` | same |
| Setting on (`PI_ACP_PI_COMMAND` = wrapper, target `pi`) | `read,bash,edit,write,probe_echo` | `read,bash,edit,write,probe_echo` |
| Setting on, user `PI_ACP_PI_COMMAND` = marker script | `read,bash,edit,write,probe_echo` | `read,bash,edit,write,probe_echo` |

The marker script recorded both invocations, `--mode rpc --no-themes --exclude-tools subagent,bg_wait,subagent_supervisor` and, on load, `--mode rpc --no-themes --session <file>.jsonl --exclude-tools …`, so the user's command ran with every original argument. The user's `~/.pi/agent/settings.json` checksum was unchanged and no file under `~/.pi/agent` outside `sessions/` changed.

## Issue #1592: Copilot `--excluded-tools`

Live probe on 2026-10-06 of `@github/copilot` installed into a temporary npm prefix. Each run used a temporary `HOME`/`COPILOT_HOME`, `COPILOT_OFFLINE=true`, and a loopback OpenAI-compatible server as the BYOK provider (`COPILOT_PROVIDER_BASE_URL`). The tools below are the `tools` array of the first chat-completions request after `session/prompt`. No GitHub credentials, paid provider, or global settings were used. `agentInfo` reports `{"name": "Copilot", "version": "<x.y.z>"}`.

| Launch arguments (`copilot … --acp`) | Model-visible tools (1.0.92) |
|---|---|
| none | `bash, create, edit, glob, grep, list_agents, list_bash, read_agent, read_bash, sql, stop_bash, task, view, write_agent` |
| `--excluded-tools=task,list_agents,read_agent,write_agent` (also the space-separated form) | `bash, create, edit, glob, grep, list_bash, read_bash, sql, stop_bash, view` |
| `--excluded-tools=bash --excluded-tools=task,…` | the above minus `bash` (repeated exclusions accumulate) |
| `--available-tools=bash,view,task --excluded-tools=task,…` (either order) | `bash, task, view` (**an allowlist makes Copilot ignore every exclusion**) |
| `--available-tools=bash,view --available-tools=task` | `bash, task, view` (repeated allowlists union) |
| `--available-tools=` | every tool (an empty allowlist is no allowlist) |
| `--available-tools=TASK,view` or `task*,view` | `view` (exact, case-sensitive names; no globs) |
| HTTP MCP server `alas` + exclusion | adds `alas-session_new`; MCP tools are unaffected |
| HTTP MCP server `alas` + `--available-tools=bash,view` | `bash, view` (an allowlist hides MCP tools; listing `alas` or `alas-session_new` keeps them) |

Copilot rejects stdio MCP servers sent by an ACP client ("Rejecting non-http/sse MCP server"), which is why Alas injects its HTTP server.

**Resume.** The exclusion follows the process, not the session. A session created with the flag and loaded (`session/load`) by a process without it got all four tools back; a session created without it and loaded with it lost them. Alas launches every attach with the session's stored policy, so this matches its activation boundary.

**Versions.** The same exclusion removes exactly the four tools on 1.0.76, 1.0.77, 1.0.78, 1.0.79, 1.0.80, 1.0.86, and 1.0.92 (1.0.76–1.0.86 also expose `session_store_sql` and `skill`, unaffected). 1.0.59, 1.0.60, 1.0.64, 1.0.70, and 1.0.75 answer `session/new` with "Authentication required" under BYOK offline mode, so they could not be measured without a GitHub account; Alas's floor is the measured 1.0.76, not the changelog's 1.0.60. Internal helpers Copilot may run without a model-visible tool are outside this claim.
