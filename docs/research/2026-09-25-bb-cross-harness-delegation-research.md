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
- There is currently **no** `disallowedTools`/`allowedTools` plumbing anywhere in `Alas/Sources` or `AlasCLI` — so a "force Alas delegation" toggle has no existing hook to attach to and would need whatever per-harness config surface ACP exposes.

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