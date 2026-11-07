# Opt-in fresh ACP v2 sessions in the local app

Status: proposed, awaiting design approval. This document describes the next implementation slice; it does not enable ACP v2 or authorize deployment.

## Purpose and scope

Let a developer deliberately start a new local ACP v2 conversation from Alas, send one text prompt at a time, see the existing canonical transcript projection, and answer adapter permission requests through the durable decision coordinator. Keep ordinary sessions on v1. Reuse the qualified package runner rather than inserting v2 frames into the v1 connection and runner.

My scope choice is a Debug-only fresh-session preview behind the existing default-off experimental ACP2 setting, plus an explicit per-new-session choice. The global setting alone never upgrades an ordinary session. The preview supports local helper brokers, built-in Claude/Codex adapters with verified launch identities, ordinary CLI authentication, text prompts, and native permission selection/cancellation. It does not advertise forms, URL elicitation, client filesystem or terminal handlers, or optional client-tool capabilities.

Queues, steering, protocol session/cancel, resume/reattach, automatic reconnection, ownership transfer, SSH/peer driving, delegation, automation, and general production rollout remain separate work. The first preview accepts no attachments or pasted-file expansion. Adapter-owned tools remain available under the adapter's approval mode; this does not promise parity with Alas v1 client tools or MCP integration.

The public name can be “ACP v2 preview.” It must explain before creation that a stopped or interrupted preview cannot resume. This is a developer preview, not a new default for users.

## Evidence and prerequisites

The package runner, ordered intake, response ledger and setup ACK barrier have merged. The live report at `docs/research/2026-11-06-acp-v2-fresh-broker-live-qualification.md`, updated November 7, records real helper startup, prompt completion, permission cancellation, durable ACK advancement and cleanup for installed Codex `2.5.0-alas.6` and Claude `0.101.0-alas.1`. Claude required the temporary driver to supply standard account/session environment variables. Neither test spoofed AIR identity.

That evidence does not establish package source provenance, approval of a positive permission selection, reconnect safety, or complete adapter capability parity. Before an adapter becomes eligible for the preview, the implementation work must establish its immutable published package/source provenance and verify a positive one-time permission selection against the real runner using a disposable scratch write. Add the evidence to the report. If either prerequisite fails, keep that adapter ineligible; do not relax checks to make its selector available.

Eligibility is an explicit record tied to adapter package name/version, resolved executable/package identity, qualified provider/authentication route, helper raw-frame/raw-reply contract, and qualified v2 capabilities. Resolve the executable to an absolute package-owned path and revalidate its identity immediately before launch. Custom commands, mutable npx latest resolution, unknown versions and custom gateways are ineligible in this slice. The eligibility set starts empty until the evidence exists. Avoid any source-version claim based only on an npm semver or SDK version.

Reuse the normal resolved launch environment and preserve the app's explicit authentication/provider configuration. Do not copy the temporary probe's seven-variable allowlist into production: it was a diagnostic constraint, not a replacement for `ACPProcessEnvironment`. Do not log credentials. A launch with a different provider or mode from the qualified record is not covered by the existing evidence.

## Selection and persisted identity

Keep `ACPProtocolVersion.current` and the ordinary `ACPProtocolSelection` v1 behavior unchanged. Add a separate fresh-preview admission policy rather than changing `supportedVersions` globally. Admission requires the Debug gate, explicit preview creation intent, local host, built-in eligible adapter, fresh empty session/history, and a current writer lease. Check eligibility and freshness again after asynchronous launch resolution and before opening the helper.

Persist a runtime-kind marker on the new session row before any broker I/O: legacy/v1 by default, and fresh-v2-preview for this path. This needs a small SQLite migration and a typed model value. Existing rows keep their v1 meaning; unknown marker values are view-only and never fall back to v1. Broad session upserts must preserve the marker once chosen, as they already preserve broker/recovery authority. Creation and marker writes use the session lease fence.

The marker is needed even if startup crashes before broker metadata is bound: a blank failed preview must not later be interpreted as a resumable v1 conversation. Broker identity, generation, raw-v2 context and remote-session binding continue to use the runner's fresh fenced transactions. Never rewrite an existing session into a preview or clear incompatible history.

Turning the global setting off prevents new preview creation. It does not switch a live preview's protocol or withdraw its current owner. Existing preview rows retain their kind after the setting is disabled and remain viewable.

## Manager ownership and startup

Install one manager-owned object per preview. It owns the `ACPV2SessionRunner`, concrete broker client, attachment epoch, current lease fence, permission presentation state, transcript snapshot writer and cleanup task. There must be exactly one runtime kind per local session; a v1 runner and v2 owner cannot coexist. The builder can choose the private container shape, but user commands and lifecycle callbacks must dispatch through one runtime discriminator.

Use existing launch resolution, local helper service acquisition, lease confirmation/heartbeat and session row creation. Construct a new unstarted `.rawV2` broker client in a fresh namespace and call `ACPV2SessionRunner.makeBroker`. Its `isCurrent` predicate checks manager membership, installation epoch, lease ownership and session identity. Install status/interaction consumers before `start`. Preserve the full startup deadline and the merged bootstrap ACK barrier. The runner owns initialize/new, canonical projection and durable operations; `ACPConnection` and `ACPSessionRunner` do not consume this source.

Do not reuse the v1 `makeBrokerConnection` path, whose restore and callbacks assume v1. Do not inject v1 policy handlers, hooks review, built-in tool services or lifecycle reducers into the preview just because their inputs look similar.

When startup refuses or fails, preserve the failed row and its protocol marker. Show the actual failure. Do not retry with v1 or mutate an existing broker. A separate “New standard session” action may create a different v1 row if the user chooses it.

## Sending and foreground state

The composer supports plain text only in this slice. Route a manual send to `runner.submit` with one submission UUID, one optimistic row UUID and the exact upstream session ID. Recheck the current writer lease after asynchronous preparation and immediately before handoff using the existing runner authority contract. Never retry an uncertain handoff automatically.

Allow one foreground turn at a time. While it runs or a permission decision is pending, disable another send; do not route through the v1 queue. Preserve edits in the draft. Programmatic send/automation/delegation entry points must return an explicit unsupported or busy result for this runtime, not silently queue through v1.

Acceptance means the prompt was registered, not that the turn succeeded. Only the canonical foreground completion publishes a terminal result to the embedding manager; idle/error, interrupted and observation-lost outcomes must not become successful completions. No next-prompt automation, automatic follow-up, checkpoint-triggered resubmission or title-generation prompt is enabled for previews in this slice.

Project stream state, transcript rows, tool-call subjects and diagnostics from `session.v2Projection`. Permission awaiting-input state is a presentation fact layered over the canonical foreground state; it does not synthesize a state_update. Loss of observation makes the display unavailable/unknown and disables actions synchronously.

## Permission presentation and authority

Keep typed coordinator handles inside the live preview owner. A presentation item has an opaque local identity bound to the installation epoch and exact handle origin, plus title, description, canonical tool-call preview and the adapter's offered option IDs/names/kinds. It must not be keyed by the wire request ID alone. Retire it on withdrawal, replacement, terminal response or owner loss. Multiple current offers may be presented in stable ledger order; do not collapse them into the v1 single pending-permission slot.

Reuse `ACPPermissionCardContent` and the existing card visuals through a new v2 presentation initializer. The v2 action callback calls the owner with its opaque item identity and the selected option ID, which resolves the still-current handle and calls `runner.decide`. No UI component obtains a raw broker reply method or a v1 policy continuation. Do not fabricate `ACPSession.PendingPermission` or use the placeholder `.number(0)` route.

Display exactly the options offered by the adapter. A positive button submits `.selectPermission(optionID:)`; cancellation submits `.cancelPermission`. No default-positive, automatic approval, remembered Alas rule, bypass-permissions flag or freeform reply is introduced. The adapter's own approved mode still controls which actions require a request; production must not silently select its bypass mode.

Disable that item's buttons synchronously when a decision begins. A committed choice remains immutable while transport observation is pending. Show a completed reply only after the durable receipt returns. An uncertain/unavailable result remains terminal for that handle and never restores clickable buttons. A genuine current successor with a reused wire ID gets a new item and can be answered independently. Remote cancellation withdraws only the matching origin.

Keep elicitation support absent, so forms/URLs are not advertised. The existing coordinator classifies and durably rejects unsupported or malformed requests under its current contracts; the UI displays the diagnostic rather than inventing a permission answer. No browser launch occurs.

## Ending, crashes and saved display

The preview does not implement protocol interruption. Replace the ordinary Stop affordance for this runtime with an explicit “End preview session” action that explains it ends the adapter and cannot resume. Escape must not silently invoke v1 cancellation or kill the process. Confirming End first withdraws runner/decision authority, then closes only this owned fresh broker with its exact source identity and current writer lease. Local runner stop alone is not adapter termination.

Normal app shutdown ends owned preview brokers. Observation loss, helper failure or lease loss first withdraws all live actions and marks the session interrupted. Never seize another writer merely to perform cleanup. Detach rather than close an adopted broker, and do not close a source for which creation ownership was never established. Track cleanup exactly once, including late-open completion after cancellation. Reuse the transport's existing late cleanup guarantees.

After app restart or tab reload without the same live installation, a preview is saved display only. Never auto-reattach, adopt, resume or execute its pending decisions, even when the helper still has the adapter. The persisted kind enforces this before any legacy restore path runs. The same-process tab switch may reuse the existing owner; closing the actual session uses the explicit End flow.

Persist a fenced display-only snapshot of projected transcript rows and row updates, including streaming finalization and terminal status. Use stable projected row identities, not the v1 runner's message-index writer. Keep this writer in the package manager integration; add a narrow projection notification seam if the existing one is insufficient. It must not mark a frame consumed, advance the ACK or restore authority. Durable v2 journals remain the source evidence; the display snapshot is not a reconstruction mechanism.

On restart show the saved transcript with an interrupted/view-only status and a clear “Conversation may be incomplete” notice. Missing snapshot content is not replaced with invented idle/success state. Pending permission cards are historical and noninteractive. Starting another conversation creates a new row. If an orphaned preview broker remains, an explicit “End remaining preview process” action may close only the persisted exact broker/generation after confirming the current writer lease and unchanged source. This is cleanup, not transfer or reattachment; otherwise leave it untouched and report why cleanup is unavailable.

## Main integration points

- `Packages/AlasCore/Sources/AlasAgents/ACP/Session/ACPSessionManager.swift`: creation admission, runtime ownership, lease checks, send/stop dispatch, guarded restore and cleanup.
- `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPProtocolVersion.swift`: preserve default v1; separate preview eligibility.
- `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPV2SessionRunner.swift`, `ACPV2SessionProjection.swift`: reuse the qualified runner and canonical projection, adding only the display-persistence seam if needed.
- Session row/store migration and `ACPSessionPersistence`: immutable runtime marker and fenced display snapshot writes.
- `Alas/Sources/Settings/AdvancedPane.swift`: reuse the existing experimental gate.
- New-session UI, `ACPComposer`, `ACPToolbar`, `ACPPermissionPrompt` and transcript/scroller surfaces: explicit preview creation, supported actions, canonical display and handle-bound permission presentation.
- App shutdown/session teardown: close the exact owned source while preserving other session owners and providers.

Keep SwiftUI/AppKit code outside AlasCore. Keep permission presentation decisions and command admission plain and testable.

## Acceptance and validation

1. Standard v1 creation, restore, queue and permissions behave as before with the Debug setting either off or on. An ordinary session never silently becomes v2.
2. Unsupported host, adapter identity, provider, dirty history or stale lease refuses preview creation before broker I/O. Marker writes survive a crash before open; a failed preview cannot fall into v1 recovery.
3. Fresh local preview startup installs owners before draining ordered methods and before releasing setup ACKs. No duplicate v1 consumer or second runtime is installed.
4. A manual text send creates one optimistic row and one durable submission. Prompt acceptance does not complete the turn; uncertain handoff never retries. Busy and unsupported send paths preserve the draft and do not queue.
5. Permission choices and cancellation go through the existing durable intent/attempt/observation path. Stale UI actions, duplicate clicks, lease loss and same-wire-ID successor requests cannot send a reply for another origin. No automatic approval is introduced.
6. End and shutdown close only the current owned source, once. Lost observation withdraws actions while storage is held. An adopted or changed-generation source is not destroyed during failed startup cleanup.
7. Restart displays only a saved, possibly incomplete transcript. It does not initialize/new, adopt, answer old requests or retry a prompt. Explicit orphan cleanup is source- and lease-fenced.
8. Exact published package/source/helper identities, a positive one-time permission selection and cancellation have live evidence before an adapter is eligible. Use disposable files and explicit expected outcomes.

Extend existing policy, manager, runner, persistence and interaction suites only where a new boundary can silently break. Add RED/GREEN regressions for those boundaries, not view-composition tests. Run affected AlasCore suites first, then focused app tests for extracted UI decisions and the local app build when UI wiring has no focused test. Inspect nonzero test counts. CI owns the full repository plan. Perform a Debug manual smoke pass for creation, text completion, a one-time approval, cancellation, End, setting-off behavior and view-only reopening; fixtures alone do not satisfy that gate.

Implementation can proceed only after this design is approved and converted into a task-level plan. Provenance and positive-approval qualification are the first tasks, so an unsupported adapter cannot become eligible halfway through the UI work.
