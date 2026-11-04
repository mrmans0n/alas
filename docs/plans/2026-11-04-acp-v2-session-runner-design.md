# Opt-in ACP v2 fresh-session runner

Status: approved in conversation on 2026-11-04.

## Intent

Continue the merged bootstrap, projection and request-decision work with one package-level owner that can drive a fresh v2 session. Today those components can be used independently, but production `ACPSessionRunner` still uses v1. Merely forwarding their callbacks would leave updates and permission subjects racing across independent streams.

The result is an explicitly constructed `ACPV2SessionRunner` in AlasSessions. A caller supplies a fresh stdio client, an `ACPSession`, persistence, a lease fence and a current-owner predicate. The runner initializes, creates the upstream session, installs projection and decisions, submits explicit prompts and exposes typed interaction events. It does not select itself in the production manager.

My scope choice is fresh stdio first. Broker pending snapshots, replay cursors and recovery need their own integration contract. The existing standalone broker components remain supported. My other choice is typed presentation callbacks rather than changes to existing permission/form views. This keeps a usable session driver separate from UI and production rollout.

## Goals and limits

- One exclusive session owner coordinates bootstrap, runtime, canonical projection and decisions.
- One intake preserves transport order between session updates, permission subjects and individual cancellation notifications.
- A permission's tool-call subject reaches canonical tool state and transcript projection before its offer callback can run.
- Explicit submission preserves local row identity and distinguishes acceptance from foreground completion.
- Stop, failure and ownership withdrawal remove interaction and write authority promptly, including when persistence is suspended.

No production default change, protocol fallback on the same client, manager queue integration, automatic next prompt, outgoing session/cancel or session/close, process launch/shutdown management, reconnect, resume, history adoption, broker installation, SSH qualification, new permission/form UI, browser opening, client tool execution or remembered approval policy. Do not advertise client filesystem, terminal or other execution capabilities that this runner does not implement. Use Alas identity. Live adapter qualification is a later gate, not a claim made by fixture tests.

## Existing components and changes

Reuse `ACPV2SessionBootstrap` for initialize/new and durable binding; `ACPV2AttachmentRuntime` for readiness and child ownership; `ACPV2SessionUpdateOwner` for canonical state and submission effects; `ACPV2SessionProjection` for stable rows; and `ACPV2RequestDecisionCoordinator` for original request handles and immutable answers.

Add the runner, a selected ordered-intake mode at the stdio facade, and narrowly scoped owner entry points needed to process that intake. Keep the existing independently consumed mode for current standalone users. A client claims exactly one mode before its first frame is routed. Ordered mode must not also feed the split update/inbound/diagnostic streams. Reject a second claim or incompatible consumer installation. The implementation may factor existing owner loops, but must reuse their validation, persistence and consumption rules rather than build a second reducer or response writer.

The concrete API names may change during planning. The ownership, sequencing and failure rules below may not.

## Ordered intake

Select ordered mode before starting the supplied fresh client. If the client has already received frames or has another intake/bootstrap owner, reject installation. The caller still owns transport lifecycle. Runner startup acquires the intake/bootstrap claims before client start; whether the runner calls the client's start method or receives an explicit start closure is a builder choice, provided no frames can precede the claim.

The client emits updates, original inbound method frames and diagnostics into one FIFO from its existing serialized frame-routing boundary. Preserve the original bytes, connection ID, receipt identity, reply-capture registration and exactly one consumption callback. A downstream merge of existing AsyncStreams is insufficient. JSON-RPC responses continue to resolve their existing request continuations, so initialize/new and prompt replies cannot deadlock behind the method intake.

Buffer method captures during setup. After session/new supplies and durably binds the upstream ID, install all consumers before draining them. A request requiring a response before setup finishes is unsupported in this session-only slice; setup remains bounded by its existing deadline and never fabricates an answer or a ready state. Validate session identity on drain using existing owners.

Register both journals and complete their empty fresh-stream initialization before draining live captures. Refuse a destination/binding that requires historical restore or adoption. Establish the fresh idle default once, before live intake. A live state already received must not later be overwritten by a delayed setup default.

For each capture, await the owning operation's durable retention, canonical application and synchronous callback boundary before advancing to the next capture. Update captures use the existing update owner. Original inbound captures use the existing inbound owner. Diagnostics keep their diagnostic status and never mint reply authority. No timestamp, relative journal ordinal or task scheduling order substitutes for the FIFO.

Do not await a user's decision, asynchronous eligibility inspection or response persistence while advancing intake. Coordinator receive schedules inspection and returns. This permits cancellation, later updates and legitimate request-ID reuse to arrive while an earlier response is finalizing.

If retention, decoding of a required canonical update, application or projection fails, stop draining, withdraw the whole installation and preserve existing failure evidence. A capture is consumed only when its existing owner contract permits it, after successful synchronous downstream application. Do not consume later buffered captures merely because an earlier one failed. Preserve the existing treatment of malformed non-update frames as classified requests or diagnostics.

## Canonical permission subjects

For a validated session permission with a known tool_call subject, the runtime's retained-inbound callback first asks the canonical state owner to apply that subject, then forwards the original inbound event to the decision coordinator. Invalid or unsupported subjects do not get coerced into valid tool updates. Command and future subjects remain typed request context only.

Add a dedicated canonical change for a permission subject, carrying its retained inbound origin and reduction effects. It derives from the committed original request, not a fabricated incoming session/update or a second update-journal record. Reuse the typed activity reduction and canonical ordering rules. Project tool effects synchronously before coordinator receive can schedule an offer. Do not advance the update journal ordinal for a subject.

Apply each subject once per original retained origin in this installation. A replayed/copy-only diagnostic cannot alter tool state. Later real updates in the FIFO may refine or replace fields normally. Do not reapply an older subject at asynchronous offer time, since that would overwrite newer tool data. Offers may consequently observe state newer than their subject. On restart this runner refuses adoption; reconstruction across separate journals is deliberately not promised.

Permission-subject changes never create foreground running/completion evidence. Callback failures or reentrant stop prevent subsequent offers and capture consumption. Recheck epoch and ownership after every external callback.

## Runner lifecycle and public operations

Expose current status and a latest-only status observation. Reliable completion and interaction events use synchronous MainActor callbacks. Bootstrap keeps its sole runtime-observation iterator; the runner uses lifecycle callbacks instead of competing for that stream.

Start is one-shot. Install projection and a bound decision coordinator in bootstrap's pre-start runtime hook, using the freshly bound upstream ID and connection context. Forward canonical publications, retained inbound events and runtime lifecycle changes only through this installation. Expose ready only after setup and both journal owners are ready. The setup deadline ends at installation readiness; it does not limit session lifetime. A v1 negotiation result reports replacement required, with no attempt to reuse the client as a v1 runner.

Use one typed interaction-support configuration to generate both initialize capability advertisement and coordinator Support. Elicitation is disabled by default. An embedding caller can opt into form and/or URL mode only by supplying a handler for their typed offers. Accepting a URL offer expresses explicit caller consent, not proof that this runner opened a browser. Forward the selected capabilities through bootstrap instead of its current empty-only advertisement. Validate the supported capability shapes against the request-contract pin recorded in the preceding decision design; reject unsupported configuration before sending initialize. Do not accept arbitrary capability dictionaries or advertise modes the coordinator will reject as unadvertised.

Submit requires ready status, matching session identity and current ownership. Accept an explicit optimistic user row and prompt params, register the row with the projection before submission registration can publish, then use runtime.submit. Validate inputs before changing the transcript. Reject concurrent local submit operations as a correctable busy result, without buffering or queue advancement. A completed acceptance releases that local submit operation but does not end foreground work or imply that another prompt should be sent. Subsequent submissions are explicit caller choices.

Keep the optimistic row and its explicit submission outcome on rejection/uncertainty; never remove evidence merely because a continuation throws. A pre-dispatch failure must not manufacture acceptance or success. Caller cancellation of submission follows the existing dispatch ownership rules and sends no new session/cancel command.

Forward typed offers, rejection handles, withdrawals, diagnostics, response evidence and URL workflow events. The caller makes an explicit decision through runner.decide with the original coordinator handle. No automatic protocol rejection is added by this runner. Withdrawal removes the visible affordance but retains historical evidence. Custom form validation stays injectable and synchronous, with ownership rechecked afterward.

Publish only live canonical foreground completion generations as completions. Prompt acceptance, permission answers, URL complete, historical idle and observation loss cannot synthesize success.

Stop is idempotent and marks the runner inactive before stopping children. Invalidate decision/write gates, stop bootstrap/runtime, settle pending local operations, withdraw interactions, release the projection epoch and expose unknown foreground. Reentrant callbacks cannot mutate a successor session installation. Caller-owned transport closure is separate. An installation that loses ownership cannot be restarted; a new owner needs a new client and an explicitly supported binding path.

Ownership withdrawal has an explicit signal: the embedding owner must call a synchronous MainActor `invalidateOwnership()` when its lease or attachment epoch is replaced, before installing the successor. This shares stop's gate withdrawal and waiter settlement but reports ownership loss. `isCurrent` remains a defensive predicate checked at operation and callback boundaries, not a subscription. Changing that predicate alone does not promise immediate UI withdrawal while persistence is suspended. No polling monitor or new lease heartbeat is added here. Tests for prompt settlement under blocked dependencies invoke the explicit invalidation method; predicate-only tests check veto at the next boundary.

## Acceptance and evidence

Extend existing suites for changes to existing types and add one runner suite. Use in-memory serialized transports, real SQLite journals and event-controlled persistence gates. Each added test must pin an integration ordering or authority contract rather than repeat forwarding checks.

Required scenarios:

1. Fresh initialize/new reaches ready and projects buffered updates once. Delayed setup cannot reset live state. A competing claim or non-fresh destination fails before consuming its traffic.
2. Update A, tool permission subject B, update C produce canonical A/B/C order while update or inbound COMMIT is held. At offer time B has been projected; C is never overwritten by a late inspection. The original request retains exact reply authority.
3. Holding inspection/response observation does not block later update/cancel intake or legitimate request-ID reuse. No second stream reader steals events.
4. Optimistic row registration, acceptance/echo in either order and live running/idle preserve one local row and separate acceptance from completion. Busy/not-ready are correctable and send nothing.
5. Stop/ownership loss at setup, COMMIT, projection, validation and writer handoff prevents later offers, writes and successor mutation. Pending operations settle without releasing a blocked dependency. Natural EOF exposes unknown, not success.
6. V1 selection and unsupported capabilities fail explicitly, and standalone split-stream stdio and broker tests still pass.

Run focused AlasCore suites for runner, stdio ingress, bootstrap, runtime, projection, canonical state, decisions and affected response owners. Inspect the actual test-count summary. Run SwiftFormat lint and whitespace checks. CI owns the full configured plan. No app build is needed unless implementation expands beyond this package scope, which requires revisiting the design.

## After this slice

Integrate broker ordering/recovery with exact current pending origins, then add production selection and presentation with qualified adapter versions. Queue/session cancellation, resume and ownership transfer remain explicit later work. This design does not authorize changing those behaviors or updating the shared umbrella issue.
