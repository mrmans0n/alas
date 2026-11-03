# ACP v2 session projection bridge

## Intent and scope

Continue #2213 after fresh bootstrap PR #2332 merged at `86f9ea68252f74fddf7ae5d8d75263092495757a`. Connect the opt-in package runtime's canonical state to an `ACPSession` without activating v2 in production. The result is a reusable, explicitly installed projection bridge, with reliable ordered delivery and attachment-scoped identity. It is a prerequisite for a later v2 runner, not that runner itself.

The user approved outlining transcript/activity projection, acceptance versus completion, committed restoration/burst delivery, and invalidation. My implementation choices below keep the bridge in AlasSessions and preserve unsupported values as typed v2 display data instead of coercing them through v1 decoders.

No production protocol selection, application manager/runner installation, request decisions, permission UI, queue dispatch, cancellation RPC, resume/adoption, transport closure, schema change, app UI changes, or adapter qualification. Do not update the shared umbrella issue without separate authorization. Preserve unrelated Ghostty and research changes.

## Existing boundaries

`ACPV2SessionState` owns transcript, activity, entity order and lifecycle. `ACPV2SessionUpdateOwner` commits journal entries before reduction and publishes latest-only observations. Its `latestApplication` and `latestSubmission` are status, not reliable effect queues. `ACPV2AttachmentRuntime` already owns those observations for readiness. A second iterator must not compete for them.

`ACPSession.transcript` has mutation helpers and stable row identities. Existing runner methods carry v1 replay, queue, permission and completion side effects. The bridge must not call those methods or synthesize v1 updates. Raw journals remain the durable authority; projected rows are an in-memory view and must not be written through legacy message persistence in this slice.

## Reliable canonical publication

Add an optional synchronous MainActor callback from the update owner, forwarded by runtime and bootstrap constructors. Install it before owner startup. It carries a monotonically increasing attachment-local revision, context, provenance and the complete relevant reduction, with access to the resulting canonical state during the callback. Publication covers replayed updates, live updates, submission registration/acceptance/uncertainty, fresh setup default and observation loss. Status-only transitions need not create fake reductions.

Each publication occurs after canonical mutation and after any required journal COMMIT, before consumption of the corresponding delivery. Setup default and local uncertainty are explicitly tagged non-journal transitions. Replayed records keep snapshot provenance. No persisted revision or new consumption authority is introduced. Existing latest-only streams remain unchanged.

Callbacks cannot suspend. A reentrant stop, runtime replacement or ownership change must be checked after callbacks and before ACK, transport handoff or successful command return. The bridge's mutation also checks its own current epoch before each external notification. Preserve the runtime's existing synchronous sibling invalidation. A projection rejection invalidates the installation rather than allowing continued current traffic with an unsynchronized model. Define one typed projection failure path; do not silently swallow callback errors.

## Installation and ownership

Introduce an explicitly installed MainActor projection object bound to one ACPSession incarnation, local ID, upstream ID, connection ID and runtime epoch. It supplies the callback during bootstrap/runtime construction and has synchronous stop/invalidate. The integration owns both bootstrap and bridge and must stop the old bridge before replacement. No global singleton or inferred ownership from remote ID alone.

Require an exclusive v2 projection destination. Reject sessions with an active legacy projector or an unrelated nonempty transcript. Existing optimistic user rows may be supplied explicitly by local UUID; do not adopt rows by matching text or timestamp. A bridge may rebuild its own projection from the owner's canonical replay during initial installation. It never clears or claims arbitrary historical rows. Reconstructing an already-populated persisted app transcript and cross-attachment identity recovery are deferred to resume integration.

The destination records the active projection epoch. Old bridges cannot clear or modify a successor's state, even when upstream IDs match. Stop leaves displayed content available but withdraws current activity and authority. It does not turn unknown into idle, successful completion or actual process exit.

## Transcript projection

Use canonical `order` and typed entity keys, scoped to this installation. Maintain a stable UUID mapping for projected rows. Updating content replaces the same row; first observation fixes canonical entity position. No full transcript rebuild per chunk. Duplicate unchanged reductions do not create rows or churn identities.

Message user/agent/thought kinds map to their corresponding ACPMessage rows. Project supported text blocks and represent supported resource/image references using existing attachment values where their meaning is identical. Keep block order, unknown blocks, raw metadata and values that the existing row model cannot represent in a typed v2 projection record associated with the entity. An unsupported content block must remain inspectable through the model, not disappear or be rendered as an invented success/empty answer. No lossy JSON round trip through AnyCodable for canonical evidence, and no new renderer in this slice.

Acceptance binds an upstream user message to the explicitly registered local row UUID. Preserve that row's local attachments, delegated source and pasted/symbol metadata while upstream content remains canonical. Acceptance-before-echo and echo-before-acceptance produce one row at the canonical observed position. Remove only the registered optimistic placeholder; never deduplicate equal text or merge unrelated IDs. Identical IDs in distinct message kinds remain distinct.

Tool calls map supported fields into existing tool rows, preserving raw status/kind and typed metadata/content in the v2 record where necessary. Plan IDs map to stable plan row UUIDs and replacement entries. Do not create file-edit rows, execute commands, mark permission approval, infer elapsed time or manufacture tool success from metadata. Builder may reuse existing pure formatting helpers only after checking they do not execute or apply v1 lifecycle heuristics.

Agent terminal values remain typed display-only v2 data associated with their terminal IDs, including exact output bytes, snapshots, metadata and unknown exit status. Tool references may expose those IDs, but must not register a process in ACPTerminalHost or advertise terminal execution. Standalone terminals remain in v2 entity order even if no legacy row exists. Current UI support for these values is explicitly deferred.

## Activity and completion

Expose a typed v2 projection state on ACPSession containing foreground state, observation availability, submission state as supplied by reductions, entity data not representable by legacy rows, and last observed completion with provenance. Existing `agentState` is connection readiness, not foreground activity; do not encode running/requires_action as failed or fabricate a permission dialog. Existing streaming indicators may be updated only by an explicit pure mapping, preserving unknown and requires_action in the typed state where the legacy enum is insufficient.

A prompt-accepted reduction updates insertion/correlation only. It cannot emit turn completion, release queues, trigger success suggestions/reports, or claim a particular submission owns a foreground generation. Live foregroundEnded effects are delivered once in ordered projection notifications, keyed by epoch and generation. Snapshot/setup-default changes populate display state without emitting historical completion notifications. Unknown stop reasons remain unknown. The bridge exposes completion facts but installs no existing app completion hooks in this slice.

A latest-only state stream cannot carry completion notifications reliably. If observers need notifications, provide a synchronous callback from the bridge carrying each relevant reduction, distinct from coalescible display invalidations. Such callbacks remain informational and are reentrancy boundaries. No background child/tool/message event independently changes foreground authority.

## Failure and restoration

Apply only context-matched publications. Validate expected revision progression and session incarnation. Initial replay reconstructs display entities without live completion effects or transport requests. Invalid context, revision gaps or local-row conflicts block the projection and withdraw the attachment through the explicit installation failure path; never guess identity or continue ACKing unseen state.

A row callback can synchronously stop or replace the projection. Check ownership before the next mutation/notification and before consumption. Avoid partially mutating a successor: prepare conversion and identity decisions first, then apply within the current MainActor epoch. No await inside a projection transaction. The builder must account for synchronous ChangeSignal callbacks during individual transcript mutations, not assume MainActor isolation prevents reentrancy.

Unknown future payloads remain canonical unhandled evidence and do not fail an otherwise valid attachment merely because they lack a legacy display mapping. Malformed journal data remains the existing owner failure, not a projection fallback.

## Acceptance and validation

Extend existing suites for owner/runtime/bootstrap callback boundaries; add one focused bridge suite if no existing type owns these behaviors. Tests must assert observable rows, typed activity and actual consumption/dispatch boundaries, not mirror private indices.

- A burst containing multiple complete foreground intervals delivers every ordered completion fact, while the latest-only status reader may lag.
- Text replacement/append, mixed entity order, tool/plan replacement and terminal snapshot/chunk updates keep stable identity and preserve unsupported data.
- Acceptance and echo in either order reconcile exactly one registered local row, retaining local-only metadata; unrelated identical prompts stay distinct.
- Replay and setup defaults cannot publish live completion, and acceptance cannot settle foreground work.
- Callback stop/replacement/lease loss cannot mutate successor state, ACK the interrupted delivery or publish late command success.
- Failure to map an unsupported block preserves typed evidence; real context/revision/identity conflicts fail explicitly.
- Existing v1 suites remain unchanged in behavior. No production caller installs the bridge.

Run affected AlasCore suites with nonzero test counts, SwiftFormat lint and whitespace checks. No native app build is necessary while changes stay in package code. Keep fixture validation distinct from CI, live adapters and SSH, none of which this design claims.

## Calls left to the builder

Choose concrete API names and callback payload layout, granular transcript mutation helpers, pure content adapters, and efficient indexing. Use a new typed session-side v2 projection value when legacy fields cannot express the data; do not widen this into a new UI or wire schema. If the existing transcript API cannot preserve identity/order safely under synchronous observers, add the smallest package-only batch mutation seam and test the actual reentrant behavior. Do not bypass that issue by wholesale resets on each update.

## Execution clarifications

The bridge exposes `registerOptimisticRow(_:)` for prompts composed after installation. The caller registers the complete local user row before passing its UUID to runtime submit. The canonical registration callback rejects missing local identity before transport handoff. This extends explicit UUID registration across the attachment lifetime; it does not discover rows by text or adopt arbitrary transcript changes.

Nested plan-cache notifications use the same guarded storage boundary as projected messages. Legacy teardown retains its reservation until synchronous row flushes and callbacks return. Projection release announces observation withdrawal and checks its epoch again after observers run, preserving a reentrant successor.

## Validation limits

The bootstrap forwarding test exercises fresh setup, despite its broader test name. Snapshot completion suppression is tested at the projection layer; a complete owner-to-runtime-to-bridge replay/provenance matrix remains unverified. Correlation tests assert UUID and attachment retention; the full delegated/pasted/symbol metadata matrix is not separately pinned. These are deferred test gaps, not claims of completed integration qualification.
