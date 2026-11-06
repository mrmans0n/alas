# ACP v2 broker runner and ordered replay

Status: approved on 2026-11-04; opt-in package implementation completed and reviewed on 2026-11-06. See the accompanying implementation plan for validation and deferred production work.

## Intent and scope

Continue the merged fresh-stdio runner from PR #2346 with a broker construction path in `ACPV2SessionRunner`. Keep its projection, decisions, explicit submission, managed waiters and ownership rules. Give broker method captures the same durable ordering guarantee as stdio while preserving exact helper request origins and broker ACK fences.

My scope choice is a fresh raw-v2 broker generation and replay/redelivery within that same live client attachment. This includes pagination, duplicate journal captures, pending-snapshot reconciliation and uncertain response evidence. It does not include reconstructing a runner after process restart, adopting an existing upstream session, reattaching a new client, protocol session/resume, or ownership transfer. Those require merging canonical history from separate update/inbound journals and reconstructing optimistic submission rows, which the current fresh runner deliberately rejects. Here, a lost attachment ends the installation rather than silently rebuilding it.

Production stays on v1. This slice adds no manager selection, native permission/form UI, browser opening, client tool execution, queue automation, outgoing session/cancel or session/close, SSH integration, adapter publication or live interoperability claim. Use Alas identity. Preserve unrelated Ghostty/research changes and leave #2213 unchanged without separate authorization.

## Current contracts and the gap

`ACPRawBrokerTransport` already validates raw wire context and generation, correlates RPC outcomes independently, tracks original request cursors, and prevents ACK advancement past protected unconsumed captures. `ACPV2ResponseAttachment` reconciles an exact current pending origin before the durable response owner invokes exact broker handoff. Keep these components authoritative.

The raw broker currently publishes updates and other frames to separate streams. In addition, `apply(snapshot)` can publish a pending request before older journal updates have been fetched. Every replay page carries a snapshot of the current tail, which can extend beyond that page's events. Merging streams in the runner or sorting one page cannot establish global method order.

Relevant source:

- `AlasACP/ACP/Broker/ACPRawBrokerTransport.swift`: start, performReplay, apply, publish, protected cursors, completion correlation and ACK flushing.
- `AlasHelper/src/acp_broker_process.rs`: `broker_attach` chooses a bounded event batch and reports `hasMoreEvents` against the snapshot tail. No helper protocol change is currently required.
- `AlasSessions/ACP/Session/ACPV2AttachmentRuntime.swift`: driven owner processing, canonical subjects and child monitors.
- `AlasSessions/ACP/Session/ACPV2ResponseAttachment.swift` and `ACPV2ResponseOwner.swift`: inspection is evidence; exact handoff still decides authority.
- `AlasSessions/ACP/Session/ACPV2SessionRunner.swift` and `ACPV2SessionBootstrap.swift`: installation, managed operations and typed capability advertisement.

Swift paths above are relative to `Packages/AlasCore/Sources/`. This is a client-side composition change against the existing raw-v2 helper protocol, not a new ACP schema revision.

## One runner and one claimed intake

Add a broker construction path to the existing runner, preserving its current stdio initializer. Broker claim acquisition is actor-isolated, so use an async construction path. Concrete initializer/factory names are left to the implementation plan. The embedding caller supplies a fresh, unstarted `ACPBrokerClient` configured for `.rawV2`, the local session, persistence, lease fence, interaction handlers and current-owner predicate.

Claim ordered mode before `client.start()` can publish an open snapshot or launch polling. Reject a started, terminated, legacy, previously claimed or incompatible client. Validate the actual claim identity when constructing runtime/bootstrap attachments and permit only one runtime consumer, including when attachment values are copied. In ordered mode, do not also yield to the old split streams. Preserve standalone split-mode stdio and broker behavior.

Reuse the ordered event vocabulary where it preserves all provenance. Updates keep their existing original delivery; broker non-update captures keep the original `ACPV2InboundDelivery` with broker ID, generation, origin cursor, journal-versus-snapshot origin, pending-request ID, connection ID and receipt consumption handle. A malformed capture remains a diagnostic or classified request under the existing rules. RPC response/outcome correlation stays independent of method intake and its COMMIT waits.

The runner opens the broker through the supplied client, then validates `opened.adopted == false`, raw-v2 context, matching local session identity, a positive generation, zero acknowledged prefix, no cached initialize/session-new response and no pre-existing operations. It uses the existing fresh bootstrap claim. A refusal does not close or replace an existing broker or retry negotiation with a different identity. Pre-session/auth interactions that prevent session creation remain explicitly unsupported by this session-only runner.

## Replay order and snapshots

Journal cursors order captures within one broker ID and generation. Control events and operation completions share that cursor domain but are not canonical method updates. Do not compare update-journal ordinals with inbound-journal ordinals, or invent receipt order from timestamps.

Validate context on every page before accepting its events or snapshot. Continue requiring the current per-page raw context snapshot; do not enable snapshot-free intermediate pages as a shortcut. Reject contradictory IDs, generation, cursor bounds and replay pages that make no progress.

For ordered mode, stage pending-snapshot candidates rather than immediately publishing them. A candidate from cursor B cannot be released ahead of unprocessed journal captures preceding B, including when B appears in the opening snapshot or the first page of a multi-page replay. Preserve its original resolution identity and register any required protection against ACK advancement while it is staged. Staging is not consumption and does not mark the origin delivered.

The journal copy is authoritative for ordering when it arrives. Release an origin once, in cursor order, and reconcile the matching snapshot copy without a second canonical subject, handle or ACK action. Duplicate identity checks include the original cursor, exact pending ID and raw bytes; the same wire JSON-RPC ID alone does not establish sameness. A contradictory duplicate fails the ordered installation rather than replacing stored bytes.

Use snapshot-tail watermarks captured from validated responses. Reaching one captured watermark establishes what that snapshot covered; newly appended events belong to later progress and do not postpone an already established barrier indefinitely. No readiness rule may depend on the broker becoming globally idle.

An unseen snapshot origin older than already delivered canonical captures cannot be inserted afterward, because its permission subject could overwrite newer tool state. If the current fresh attachment cannot prove its place in the observed journal prefix, expose incomplete observation and withdraw the installation. Do not present that request, ACK it as consumed, fabricate missing history, or label the projection complete. Snapshot-only recovery across a pruned prefix belongs to the deferred reattachment design.

Keep control-cursor ordering and existing completion protection intact. Journal fetch and RPC correlation may proceed while local capture retention is blocked; only canonical method application waits on the preceding method's durable processing. Broker status such as stdout closure or write uncertainty is factual transport evidence, not a foreground success event.

## Durable processing and canonical state

Generalize the fresh driven runtime path to a validated fresh broker source. Both journal owners prepare empty streams, submission history is empty, the initial source prefix is known, and the fresh idle default is established once before draining method captures. Reject historical local bindings rather than invoking the old independent replay loops and pretending the result is ordered.

For each ordered method capture, await its existing owner's COMMIT, validation, canonical application and synchronous downstream boundary before starting the next method. A known permission tool-call subject is reduced through the canonical owner from the committed inbound origin, then projected, before coordinator receive can offer it. A later real update remains later even if eligibility inspection completes slowly. Permission subjects do not create fake update-journal records or foreground lifecycle effects.

Derive live-versus-historical classification from the validated installation boundary, not from receipt insertion alone. A historical or unorderable capture cannot publish a live completion. Stable row IDs, explicit prompt correlation and acceptance-versus-completion behavior remain those of the merged runner.

Do not hold method intake for eligibility inspection, user input, or response observation persistence. In particular, a request ID reused after the previous exact response was physically written remains eligible when its own fresh pending origin is current, even if prior bookkeeping is unfinished. Simultaneously ambiguous current origins remain unavailable.

## Broker identity, ACK state and operation keys

Before initialize/new, persist the validated broker ID, generation, `.rawV2` context and initial zero ACK under the session's lease fence. Use a fresh-only transactional check/CAS against existing session fields and v2 history, not an unconditional overwrite. Permit empty broker fields, or an identical already recorded fresh identity with zero ACK; reject an existing remote binding, archived/recovery state, incompatible identity or history. Reuse existing columns and lease checks; no schema migration is part of this slice.

Expose ordered durable-state notifications from the claimed broker attachment to the runner. After the helper accepts an ACK, mirror its monotonic cursor through the existing fenced `updateACPBrokerAcknowledgedCursor` path, checking attachment identity and epoch around awaits. Serialize these writes or use their existing monotonic same-generation contract. A false fence/CAS result or storage error withdraws the installation. Do not replace a generation or reset a cursor through an old callback. Constructor callbacks supplied by the embedding caller must be observational, with no second ACK/state writer or decision consumer.

ACK means durable receipt retention, not request resolution, user consent or operation success. Keep the transport's protected-cursor floor and response-completion protection. A held update/inbound COMMIT prevents ACK from crossing that capture even if later helper-only controls have completed. Snapshot staging has no independent consumption authority. A local cursor mirror can lag an already accepted remote ACK if its write fails; report that failure explicitly and make no cross-system atomicity claim.

Choose stable, nonempty operation keys before dispatch for initialize, session/new and every explicit prompt submission. Keep setup keys fixed for the installation and derive a prompt's key from its explicit submission identity under that installation. Preserve the coordinator's existing immutable response intent, attempt and key. The current stdio caller API need not expose broker keys. Do not generate a new key to retry an uncertain operation, replace a chosen answer, or silently resend a recovered prompt.

## Fresh pending-request reconciliation

Use the existing exact response path with the current original capture. Read-only pending inspection must not replay events into canonical state, consume receipts, advance ACK or resolve a request. The current broker ID, generation, connection, pending key, original cursor, raw frame and exact wire ID must agree. No ledger row or pending-snapshot payload alone grants authority to answer.

Individual cancellation and URL completion remain scoped to the matching broker generation and preceding request origin, using cursor-qualified ordering. A cancellation for a retired origin cannot cancel a later reuse of its wire ID. A selected immutable answer is not replaced by cancellation. URL completion remains independent of consent and transport delivery evidence.

Recovery in this design means safe redelivery and reconciliation in the same live installation. It does not reopen a historical row as a current handle, restore a process after observation loss, or authorize a second response attempt whose write outcome is uncertain. Existing durable intent and observation inspection continues to report chosen/uncertain/unavailable facts faithfully.

## Failure, invalidation and ownership

Retain the runner's explicit synchronous `invalidateOwnership()` contract. The embedding owner calls it before installing a successor; `isCurrent` remains a defensive predicate rather than a subscription. Stop remains idempotent, settles managed start/submit/decide waiters without releasing blocked dependencies, withdraws interactions and releases only its own projection epoch.

The ordered broker claim additionally carries transport validity. Poll failure, context/generation mismatch, stdout closure, write uncertainty or detach invalidates that source before merely finishing its buffered method stream. Expose a reliable terminal notification independently of the method worker so a blocked COMMIT cannot keep the installation apparently usable. Every canonical callback, receipt-consumption boundary and future handoff checks source validity as well as ownership. A late storage return or queued control callback cannot regain authority. Terminal notification is availability, not a second canonical method stream.

Process an invalidation as loss of observation: current foreground becomes unknown, unfinished evidence remains uncertain, and no synthetic foreground completion is emitted. A command handed off before loss can remain uncertain; the runner cannot retract remote I/O already accepted by the helper. Detecting a replacement generation ends this runner instead of adopting it.

The caller continues to own broker process/connection lifecycle. Runner stop withdraws this installation; it does not issue helper close, session/close, or kill the adapter. The embedding caller may detach its client explicitly. A failure after opening or sending setup retains its uncertainty and does not erase metadata or close another owner’s process.

## Acceptance and validation

Extend existing broker/runtime/bootstrap/persistence/runner suites. Reuse the in-memory broker service fixture and real SQLite journals. Parameterize meaningful source variants; do not duplicate the stdio runner matrix as forwarding tests. Use event-controlled gates, Swift Testing cancellation/deadlines and the existing shared helpers, with no new short per-read timers or serialization.

Required evidence:

1. Fresh broker creation reaches ready, binds the exact source under the lease and installs projection/decisions before buffered captures. Adopted, legacy, already initialized, nonzero-prefix, conflicting persisted identity and historical-local-state inputs fail without overwrite or setup resend.
2. A multi-page journal with update A, permission B and update C keeps A/B/C order when an early snapshot already contains B. A held local COMMIT blocks later application/ACK but not RPC response correlation. No pending snapshot overtakes its journal origin or causes duplicate canonical effects.
3. Matching journal/snapshot redelivery yields one subject, row and decision handle. Conflicting bytes/key at one cursor, missing orderable history and a page with no progress withdraw observation before later effects or ACK.
4. Stable initialize/new/prompt keys are present on broker sends. Accepted/echo ordering preserves one optimistic row. No new-key retry, prompt resend or invented success occurs after uncertain send/reply evidence.
5. Physically written answer B can be followed by a new current origin using the same wire ID while B's observation COMMIT is held. Current-origin inspection and exact handoff still reject ambiguity, stale keys, old generations and replacement origins.
6. Cancellation and URL completion respect origin cursors, including delayed pending-snapshot data. Read-only inspection produces no ACK or canonical mutation. Receipt ACK remains separate from helper pending-request resolution.
7. Stop, explicit ownership withdrawal and transport invalidation during open, setup, metadata persistence, method COMMIT, validation and exact handoff settle local waiters and prevent late offers, consumption and successor mutation. Generation replacement is terminal. A blocked method worker does not delay availability withdrawal.
8. ACK mirrors remain monotonic and fenced; a delayed old callback cannot update replacement metadata. Failure after remote ACK but before local cursor persistence is reported honestly. Caller-owned stop/detach/close boundaries are asserted.
9. Existing stdio runner and standalone split-mode broker suites stay green. A source that keeps appending after a captured snapshot watermark cannot indefinitely postpone the established ordering/readiness barrier.

Run focused AlasCore suites with nonzero test-count summaries, formatter lint and whitespace checks. Broaden locally only for a reproduced concurrency interaction, as repository policy permits. CI owns the full configured plan. Tests establish fixture behavior only; published adapter/helper and live SSH qualification remain later gates.

## Subsequent work

After this slice, design production selection and interaction presentation against qualified adapter versions. Keep cross-attachment reconstruction, session/resume, cross-owner transfer and queue/session cancellation as explicit later designs. This document authorizes none of those integrations.
