# ACP v2 initialization and fresh-session bootstrap

## Intent and scope

Follow attachment-runtime PR #2329, merged at `8ae5ff36b894c6a77cfe514a3ae71fa09620c73c`. Provide an explicit package API that initializes a v2 attachment, creates a fresh upstream session, and hands it to the existing runtime. Today `ACPConnection.initialize()` constructs v1 capabilities and rejects v2 results; its session methods decode the permissive v1 result. The runtime correctly requires an already-established upstream session.

This is opt-in package integration. `ACPProtocolSelection` and production eligibility remain v1-only. Existing v1 connection methods and callers keep their contract. Do not turn the Debug flag into live eligibility, install the application runner, project UI, execute adapter requests, or advance queues. Resume/load/fork, cross-version resume, authentication execution, adapter publication and SSH qualification are excluded. No new schema is planned.

My scope decision is fresh sessions first. Resume requires replay/current-state provenance and history replacement rules that deserve a separate design. Initialization success is not a qualification claim.

## Wire contracts and identity

Use a separate v2 bootstrap API rather than changing `ACPInitializeOutcome` into a mixture of schemas. Reuse `ACPV2InitializeParams` and version-first `ACPInitializationResult` decoding. Identify the client as Alas. Advertise only capabilities actually implemented by this slice; do not copy filesystem, execution, AIR or legacy extension markers from v1. Keep the exact raw initialization response alongside interpreted fields. Existing generic JSON decoding limits remain explicit; keeping raw bytes does not make its projection lossless.

Initialization is single-use for a connection epoch. Require the concrete client's immutable mode to be v2 before sending. A selected v2 response must pass its schema and identity validation. A valid selected v1 response produces an explicit replacement-required outcome, preserving the response evidence. It never changes this client's routing mode or creates a v1 session on the v2 attachment. The caller owns disposal/replacement and any later v1 initialize. No automatic retry or second initialize; authentication, malformed results and transport failures are not downgrade signals. Unsupported versions fail explicitly.

Keep v2 capability/authentication data separate and opaque where not implemented. Require an object `capabilities.session` before sending session/new; omitted/null/malformed markers do not grant the method surface. Require the advertised object marker for every requested MCP transport. Expose initialization as a distinct completed phase before the explicit create-session call, so future authentication can fit between them. Do not reuse `ACPConnection.authenticate()` or silently continue past an authentication-required error. Such errors remain inspectable and terminal for this bootstrap operation; a new attempt needs explicit caller action and current attachment authority.

Add dedicated fresh-session params/result types. Validate a nonempty actual `sessionId`; preserve raw response bytes and unknown fields. Preserve initial `configOptions` and `availableCommands` as setup data, with interpreted validation only where needed for runtime installation. Do not funnel them through permissive `ACPSessionNewResult`, invent defaults for malformed required fields, or claim config/command UI support. Any interpreted optional field follows the pinned contract, including tolerant available-command handling. No v1 metadata/extensions are copied implicitly. Caller-provided workspace/MCP inputs must satisfy the chosen v2 contract; unsupported transports/configuration fail before dispatch where locally knowable.

Contract sources: the repository's existing initialization schemas/tests and the pinned upstream [initialization](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/initialization.mdx) and [session setup](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/session-setup.mdx) documentation. Both were fetched during design; initialization was retrieved through GitHub after the browser fetch failed. Its blob SHA is `6c0991c9ccbe16a3eef2030c02144b10c734afb7`. If sources materially conflict with these decisions, report the concrete conflict before changing scope. This is not a rolling latest-schema migration.

## Ownership and API

Add a MainActor bootstrap coordinator in AlasSessions, using concrete stdio and raw broker descriptors, one local session ID, lease fence, persistence actor, and current-ownership predicate. Keep wire types in AlasACP. Exact names and narrow protocol seams are builder choices.

Public phases distinguish idle, initializing, initialized, creating, installing, ready, replacement-required, failed/uncertain, observation-lost and stopped. Initialization and create are explicit single-flight operations; overlapping calls cannot dispatch duplicates. Repeated calls after a handed-off or uncertain create do not resend. An operation key for broker calls is supplied explicitly and remains stable. Never generate a new key to escape an uncertain outcome.

Return typed initialization evidence separately from the installed-session result. The latter contains the actual upstream ID, raw setup evidence, setup metadata and runtime. It is published only after persistence and runtime readiness. The coordinator retains lifecycle responsibility for that runtime for this epoch; stopping the coordinator stops it. Underlying process closure stays with the connection owner. No detached child can survive a stopped bootstrap and later become current.

The caller must supply an explicit setup deadline or cancellation policy. A blocked initialize/create can be stopped promptly without waiting for its dependency. Tests inject the deadline/clock boundary rather than sleep. Cancellation or timeout after request handoff means uncertain, not not-created. Preserve local response evidence if available, and never automatically close a possibly created remote session or retry session/new. Cleanup RPCs are effects and require a future explicit contract.

## Early ingress and runtime installation

Preserve original facade deliveries, including update, method and diagnostic streams. Do not introduce a second iterator on any AsyncStream, drain and reconstruct captures, or infer a session ID from an early request. Before the actual setup result is validated, no session-bound journal, request offer, answer or consumption is authorized.

Prefer retaining the facade's existing queued deliveries until runtime installation, which then becomes their sole consumer as today. This adds no new competing reader or replay pump. Queued deliveries keep original receipt IDs, bytes and acknowledgment handles. The current facade buffers are not claimed to have a new memory bound; sustained startup traffic/resource qualification remains open. The setup deadline limits the lifetime of a stalled bootstrap, not the bytes a peer can send.

After validated setup, atomically persist the actual upstream-session binding through the existing lease-fenced store path before acknowledging the setup response. A narrow persistence operation must compare the expected local-session binding and attachment context, avoid overwriting an existing incompatible upstream ID, and return only after COMMIT. Validate its receipt/current fence after awaits. Reuse existing storage where its atomic contract suffices; add a focused transaction if it does not. Do not accept an arbitrary callback as proof of durable installation.

Create and start the runtime only after that binding commits. Drain the queued original deliveries through its existing owners; their own retention rules still govern consumption. A malformed or wrong-session update fails explicitly rather than being filtered or consumed as another session's traffic. Early valid adapter requests can be offered only after their normal inbound COMMIT. Answers remain explicit caller decisions after runtime readiness.

For a fresh session, the canonical model's setup-default idle is only a default. Earlier reported running/requires_action must survive the setup response. An initial idle state cannot report a completed turn. Do not classify traffic using when an async call resumes or a latest-only status event. No resume snapshots or history replay are introduced here; if existing fresh-state reduction fails these cases, fix that concrete boundary with a regression, not a generic replay mechanism.

An adapter that waits for a pre-session interactive answer before returning setup cannot be supported by this API: there is no invented session-bound authority to answer it. Preserve its captured evidence, expose the blocked phase, and honor explicit cancellation/deadline. No automatic denial, permission UI or OAuth callback is installed. Requests received immediately after the setup response but before its awaiting task resumes remain queued and answerable after installation.

## Broker and failure boundaries

Accept only fresh raw-v2 broker bootstrap with matching local session, broker ID, generation and connection. Its exact concrete client's open result must have `adopted == false`, nil initialize/session response caches, empty operation snapshots and acknowledged cursor zero. This is the existing helper's newly spawned supervisor provenance, not an inferred absence of traffic. Do not require journalTail zero: unsolicited startup frames may already exist and must remain queued. Add a single-use claim in the concrete client/transport that atomically rejects prior initialize/session sends or an already claimed bootstrap. A stale open-result value alone is insufficient. Apply the same exclusive claim rule to direct stdio bootstrap. Integration must supply an attachment whose facade streams have no other consumer; public AsyncStream values do not themselves expose a reliable iterator-ownership check. The API must document this precondition rather than claim to detect arbitrary external iterators.

Reattachment to a broker with prior or uncertain setup is explicitly rejected by this fresh-session API. There is no exact-operation recovery exception in this slice. Do not use legacy normalized snapshot caches. Full adoption/recovery is deferred. Competing external-process ownership remains governed by the existing lease contract; the in-memory claim prevents duplicate local coordinators, not cross-process exactly-once setup.

Use the existing raw RPC delivery and explicit consumption contract for initialize/setup responses. Acknowledge initialization only after validated evidence is retained by the bootstrap result; setup response acknowledgment follows durable binding. These do not grant acknowledgment authority for early update/request receipts. A later receipt's consumption must not cross an earlier uncommitted broker cursor. Error/malformed/uncertain evidence stays explicit; no new receipt is fabricated from cached data.

At every owned await boundary and immediately before dispatch, installation, acknowledgment or public success, verify epoch, cancellation and ownership. Stop first withdraws local authority and stops an installed runtime, then settles blocked callers; late returns may remain historical evidence but cannot start runtime, consume or publish success. External ownership replacement still requires the lifecycle caller to stop the coordinator. Preserve uncertainty when cancellation races COMMIT or a physical write. SQLite and transport I/O are not an atomic cross-process protocol.

## Acceptance and verification

Use real SQLite and actual client routing with event-gated fake transport/service boundaries. Extend existing schema/negotiation suites and add one coordinator suite; no fixed sleeps, default serialization, duplicated forwarding tests or whole-plan local run.

- Exact v2 initialize params use Alas identity and implemented capability markers; v1 calls retain existing encoding/behavior. Selected v1 requires replacement with no second initialize or session dispatch. Malformed/unsupported/auth/transport failures never trigger fallback.
- Overlapping initialize/create calls and retries after uncertain handoff send at most one relevant operation. Explicit phases cannot be skipped.
- Valid setup ID is committed under the current lease before setup response consumption or runtime publication. Bad ID, conflicting stored binding, injected SQL failure and lost lease produce no runtime/ack.
- Actual updates and original requests arriving before/during/just after setup are retained once by the runtime. No duplicate iterator, request offer before COMMIT, fabricated upstream ID or reconstructed stdio reply authority. A legitimate request after the response remains answerable even if the awaiting task has not resumed yet.
- Running/requires_action before setup return survive installation; initial idle and prompt acceptance do not create completion. Malformed and wrong-session evidence cannot silently disappear.
- Stop/cancel/deadline during initialize, create, binding COMMIT and runtime restoration settle callers promptly; late results cannot install or mutate a successor. An uncertain create is never retried or remotely closed automatically.
- Raw broker response/update/request receipts preserve the protected ACK prefix in both persistence orders; mismatched/cached/previously uncertain attachments cannot create fresh setup authority.

Run affected package suites with nonzero counts, SwiftFormat and whitespace checks. No app build unless app code becomes necessary, which would be a scope change. Keep fixture, CI and live/published-adapter/SSH evidence separate.

## Delivery

One fresh builder check before full-design approval. Then write the implementation plan and execute inline with TDD, one fresh final review and one combined material fix pass, no rereview. Leave implementation uncommitted until shipping is requested. Preserve unrelated Ghostty/research changes. No product changes before full-design approval.

## Builder check outcome

The fresh read-only builder check confirmed the core ordering can be planned and identified one freshness decision. Adopted broker state cannot authorize a fresh session/new. The decision above uses the helper's positive new-supervisor result plus a concrete-client single-use claim, and removes the exact-operation recovery exception. The helper returns adopted=false only on its newly spawned path; concurrent opens return adoption instead. No durable operation schema is added. No product code or tests changed during design.

## Execution clarification

The implemented binding receipt is tied to the configured store path and exact lease bytes. A genuine receipt from another database cannot authorize runtime installation. Bootstrap stdio uses the factual frame writer's post-serialization authorization boundary, preserving unknown write outcomes and preventing queued unwritten frames from acquiring stale authority. Claims are checked again after authorization callbacks. Installed runtime observation loss withdraws bootstrap status; the final operation check also inspects the actual runtime after any external predicate. Setup config/command data remains raw evidence. The explicit fresh idle default is applied before ingress through setupDefault, not as a fabricated durable frame.
