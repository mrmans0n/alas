# ACP v2 attachment runtime

## Intent and boundary

Continue #2213 after response-owner PR #2325 merged at `99e3cc411891695ad39d68fe9dda8644af1fcb09`, reviewed head `449aed3d55c34be9d9446eba7bfa36600e132230`. Assemble the existing v2 update/submission owner, inbound receipt owner and response owner under one attachment lifecycle. This gives the later runner integration one coherent API instead of requiring it to coordinate several independent owners and stream consumers.

The concrete missing link is reliable delivery of each committed request together with its original capture. `ACPV2InboundReceiptOwner.observations` is latest-only status; using it as a request queue would lose offers during bursts and cannot recover original stdio delivery authority. Add a fenced post-commit handoff, then compose the owners around it.

This is an opt-in package runtime for an already-established upstream session. It does not change production protocol selection, install an app runner, choose permission answers, execute methods, add UI projection, advance application queues or qualify adapters. Production remains v1-only. Initialization/setup and requests arriving before an upstream session is established need their own later integration contract; never invent an upstream session ID to journal them here. No new schema is planned.

## Concrete attachment and exclusive ingress

Construct one runtime for one local session, established upstream session, immutable v2 attachment, lease fence, persistence implementation and current-ownership predicate. Provide concrete stdio and broker construction paths. The broker path requires the validated open result and matches local session, broker ID, generation and connection across all child owners. Reject v1 clients and incompatible descriptors before starting work.

The runtime is the only integration entry point subscribing to this attachment's update and non-update ingress. Reuse the facade's existing routing: session/update goes to the update owner; other raw method/request/diagnostic frames go to the inbound receipt owner. Each child is the sole consumer of its assigned source stream. Do not add a second iterator on an AsyncStream or reconstruct a combined total order across independently routed streams.

The update owner remains the authority for canonical state, ordered application, durable update consumption and submission/acceptance correlation. The inbound owner remains the authority for retaining exact request evidence and acknowledging durable receipt. The response owner remains the authority for chosen response registration, exact current-origin handoff and saved outcome facts. Runtime composition must not duplicate their state machines.

## Reliable post-commit request handoff

Extend the inbound owner with narrow injected callbacks for validated stream registration and each validated live retention receipt. The live callback receives the original delivery and its committed receipt. Invoke it for both inserted and duplicate live captures after COMMIT and proof validation; never invoke it for historical replay. It runs on MainActor, cannot await an answer, and is followed by another ownership/stop check before durable consumption. A reentrant stop withdraws consumption authority.

The runtime creates the response owner from the validated inbound stream and the same attachment/fence. Validate the callback binding against that runtime before exposing it. A notification or malformed common header remains retained evidence but creates no answerable request. Method-specific interpretation stays with a future decision policy.

Expose valid requests as opaque runtime-local handles with read-only retained record/source information. Only the runtime can construct these handles. Each binds the original live delivery where stdio requires it, the committed retained origin and this runtime epoch. A handle is not serializable and cannot be made from a history page. The response owner still performs current-origin checks at use time.

Deliver request handles through a synchronous MainActor callback, installed at construction, not through latest-only observations. Callers retain handles they need and make explicit response calls later. Do not await a human response inside ingress processing. Deduplicate repeated live delivery of the same stream/ordinal within an attachment so copied captures do not offer another question. A new broker attachment may offer its actual pending capture again, bound to that new runtime; historical replay alone may not.

The callback can observe requests while the other journal is still restoring, but runtime submission/response commands remain disabled until both owners are ready. This avoids holding ingress or consumption on another stream's readiness. The caller sees the runtime readiness state and can submit its explicit decision once ready. No implicit answer, automatic retry or new operation key is introduced.

## Readiness and commands

Start once. Restore the existing update/submission history and inbound history through their current bounded APIs, then read current owner states. The runtime becomes ready only when the update owner is live, the inbound owner is receiving, their descriptors match this epoch and ownership remains current. A request offer received earlier remains a handle, not a promise of present readiness or future acceptance.

Expose canonical state through the update owner and a latest-only runtime status stream. Latest-only status is appropriate for invalidation/readiness because consumers inspect current state; it is not an effect queue. Do not forward latestApplication snapshots as a reliable list of effects or infer foreground completion from a prompt RPC response.

Expose explicit submit and respond commands. Submit delegates to the existing update owner's submission capability with the caller's stable submission/local-row identities and exact operation key where required. Respond accepts a runtime-local request handle, exact chosen response frame and explicit intent/attempt/key identities and delegates to the existing response owner. Both recheck current runtime/epoch/readiness at each owned await boundary. Retain the existing distinction between an uncommitted local transport fact and a durable observation receipt. Restored or potentially committed attempts never initiate another handoff.

## Stop and observation loss

The runner-facing lifecycle API must make invalidation synchronous. Runtime stop first withdraws its own epoch, stops the response owner, then stops inbound and update/submission owners and finishes its status stream. It does not wait for blocked persistence, I/O or application callbacks. Already-started transport effects are governed by the existing uncertain-outcome contracts; no late return can revive readiness or publish current success.

Observe child status/stream endings. A blocked owner or unexpected observation loss withdraws the whole runtime's command authority. Already-retained history remains inspectable. Intentional parent stop is distinct from unexpected disconnect, and neither fabricates idle, successful completion, cancellation attribution or a safe resend. Read each child's actual final state after its observation stream ends, rather than assuming every end is a new failure.

The lifecycle caller must still invoke stop on lease or attachment replacement. The current predicate is a boundary check, not a lease-change subscription. Runtime stop does not close or replace the underlying client process; the existing connection owner remains responsible for detach/close. Keep this ownership split explicit so composition cannot close a successor attachment or shut down a shared transport twice.

Durable consumption remains receipt acknowledgment, independent of offering a request, choosing an answer or completing a write. The runtime never manufactures callbacks, consumes historical records, advances broker ACK state directly or locally resolves pending requests. Cross-process lease arbitration and pipe I/O are still not atomic.

## Execution clarification: stdio diagnostics

The stdio facade has a third stream for rejected/unmatched RPC diagnostics. The runtime reads it once and adapts it into inbound retention alongside the original method stream. The adapter preserves the raw diagnostic receipt UUID, bytes, connection and single-use consumption. These adapted captures never enter the reply registry and are excluded from request offers. No total order across these independent facade streams is claimed. If either source ends or a source reader observes ownership loss, the runtime withdraws its whole epoch.

## Acceptance and verification

Use the existing real SQLite persistence and event-gated stdio/broker fixtures. Add a runtime suite for composition; extend existing owner suites for changes to their callback contract. No fixed sleeps, new serialization traits or duplicate transport-only tests.

- V1 and mismatched attachment/session/generation descriptors are rejected without consumption or outgoing writes.
- A burst exceeding the latest-only status buffer produces every distinct committed live request offer, retaining original stdio authority. Copied deliveries offer once; historical replay offers none. Valid requests, notifications and malformed envelopes retain their intended distinction.
- Retention failure produces no offer or consumption. Stop during COMMIT, before callback, or reentrantly inside the callback cannot consume or publish an actionable successor handle.
- Submission and response commands reject before readiness, after observation loss and after stop. An early offered handle works only after readiness and fresh reconciliation, without automatic retries.
- A real submit/acceptance plus running/idle update sequence passes through the composed owner without manufacturing completion from acceptance. Request answers still commit before one exact write and never consume inbound evidence as a response side effect.
- Broker update and request receipts preserve the existing ordered ACK prefix when their persistence completes in either order. Same-generation pending capture on reattachment is offered as current evidence; historical records, reused origins and changed generations cannot create authority.
- Either ingress ending or a child blocking invalidates all commands. Stop settles blocked response callers promptly; late returns and old handles cannot mutate a replacement runtime. Underlying transport closure stays with its existing owner.

Run affected package suites first, inspect actual counts, then SwiftFormat and whitespace checks. This slice touches package code/tests only, so no native app build is required. Keep fixture, CI and live adapter/SSH evidence separate. The established native/opaque-parser qualification gaps remain open.

## Delivery and calls made

My calls: assemble a post-setup package runtime before app-runner installation; add reliable synchronous post-commit request callbacks rather than treating status as a queue; expose opaque epoch-bound handles; allow offers during restoration while commands remain readiness-gated; stop owners without owning process closure. These keep the integration testable without silently enabling v2 or claiming startup/semantic support.

One fresh builder check reviews this design before approval. After full design approval, write the implementation plan and execute inline with TDD, one fresh final review and one combined material fix pass if needed, without rereview. Leave implementation uncommitted until shipping is requested. No product code or schema changes before approval. Preserve unrelated Ghostty/research changes.

## Builder check outcome

One fresh read-only builder check examined the existing receipt registration/retention, facade capture, response reconciliation and update/submission lifecycle APIs. It returned "nothing important left". Original stdio deliveries and duplicate broker retention receipts can cross the proposed live callback without reconstructing authority. No product code, schema or tests changed during design.
