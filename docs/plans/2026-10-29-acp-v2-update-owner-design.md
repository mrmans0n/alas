# ACP 2 ordered update owner

## Intent

Connect the merged raw delivery, durable update journal and canonical v2 session model through one asynchronous owner. The journal currently leaves receive ordering and consumption to its caller. This slice supplies that caller and proves the receipt-to-application boundary before enabling v2 connections.

Implement a UI-free owner in AlasSessions, alongside ACPSessionRunner and the journal. It owns one ACPV2SessionState and one exclusive incomingV2Updates iteration for an explicit attachment. It can be exercised with existing stdio/broker fixtures and real SQLite persistence. Production ACPProtocolSelection remains v1-only. ACPSessionRunner's current v1 consumer and queue behavior remain unchanged; this owner is the component a later v2 runner path will install, not a second consumer beside an active runner.

## Scope

- Ordered historical reconstruction followed by ordered live ingestion for one explicit journal stream.
- Required writer lease, immutable connection/session/source identity and synchronous attachment invalidation.
- Durable receipt before model application, and explicit consumption of the original live delivery only after both succeed and ownership is still current.
- Retry deduplication by committed journal ordinal, including broker redelivery after restoration.
- Observable canonical state and typed interpretation, storage, ownership and stream-end outcomes.

No prompt sending, registration/acceptance recovery, RPC or pending-request durability, permission answers, UI/message-row projection, queue advancement, usage, success suggestions, upstream resume, SSH replication, adapter changes, or live v2 eligibility. Lifecycle reductions are data for later integration; this component invokes no turn-completed or queue callback.

## Ownership and execution

My design choice is a MainActor owner because the existing runner and its attachment checks are MainActor-owned. Its state reductions and invalidation stay synchronous. Persistence awaits the existing ACPSessionPersistence actor. Do not rely on actor isolation alone to preserve receive order across awaits: one managed task iterates the stream and awaits each operation before advancing. Repeated start cannot create another task or split the stream. There is no public concurrent ingest path that bypasses this sequencing.

Creation binds local session ID, upstream session ID, journal source, expected transport connection UUID and a current writer lease fence. A broker attachment also requires an immutable historical-through cursor from its validated ACPBrokerOpenResult snapshot, bound to that same broker ID/generation. Capture it before draining deliveries. It is an attachment observation boundary, not an ACK cursor or a claim of full history. A new direct-stdio connection starts with live provenance; adopted/unknown direct streams cannot silently use that fresh-connection contract. Callers provide a synchronous current-attachment predicate; absence of current authority fails closed. Source and context cannot be changed in place. A new attachment creates a new owner and fresh canonical context. Reuse existing transport identities; if a minimal read-only client identity accessor is necessary for a fixture-backed adapter, add it without altering v1 routing or protocol selection.

Stopping invalidates the owner synchronously before cancelling/awaiting its task. Check cancellation, owner epoch, attachment predicate and matching connection before each operation and again after every persistence await. Lease-fenced registration/append remains the database authority. An invalidated owner may leave a committed receipt, but cannot publish model state, emit live reductions or consume its delivery afterward. There is no await between the final authority check, state publication and original callback invocation. Transport callbacks retain their own existing generation/attachment fences.

A lease replacement can race after a committed append; that receipt remains valid evidence. The live attachment predicate must include the caller's current writer authority. This slice does not claim an atomic transaction spanning SQLite COMMIT and a remote helper ACK. Any external lease change not yet observed by the caller remains subject to existing transport and lease ownership rules; do not introduce a new lease mechanism or claim the journal solves that distributed boundary.

## Startup and historical application

First register or reopen the requested stream using the required fence. Reconstruct that stream through bounded journal pages before draining buffered live deliveries. Apply stored records in ordinal order to the fresh state context with source snapshot. Original receipt/connection/provenance remain journal evidence; they do not supply current callback authority. Historical state never produces a new foreground completion.

Track the last successfully interpreted/applied ordinal for this owner. Unknown future updates are explicit unhandled reductions and count as processed, with their exact frames retained. A nonzero initial broker baseline remains exposed as a known missing prefix; end-of-journal never claims full upstream history or complete prompt recovery. Do not replay unrelated streams or merge generations automatically.

Malformed known updates, invalid notification envelopes or a decoded upstream session mismatch stop reconstruction with a typed interpretation failure and the offending ordinal. Keep the persisted bytes and successfully rebuilt prefix. Do not skip the failure and report a complete model. The owner exposes that it is blocked and does not proceed to live effects. No historical record can acknowledge a transport delivery.

## Live receipt, application and consumption

For each delivery, validate the expected connection UUID and source provenance before storage. A stdio source requires the registered stdio UUID and no broker provenance; broker source requires matching ID/generation and a positive cursor. Stale deliveries cannot append or consume.

Append the original bytes through the registered stream and captured lease fence. The journal checks current descriptor and lease atomically. After the await, recheck attachment ownership. A storage error blocks this owner without application or acknowledgement. Do not automatically retry failures or move to later updates; a future attachment can recover committed evidence.

The returned durable receipt supplies the canonical ordinal and original record. If that ordinal was already processed during restoration or this attachment, skip model application but allow this still-current original live handle to be consumed. Equal bytes with distinct stdio receipt IDs remain distinct updates. Broker reconnect duplicates keep their original journal identity. A later unprocessed ordinal must follow the processed prefix; unexpected gaps fail explicitly rather than silently changing application order.

For a new ordinal, decode the committed record and apply it to a trial canonical state. A broker delivery at or below the immutable attachment historical-through cursor uses source snapshot even if it was absent from the local journal. A cursor above that boundary uses source live. A delivery from a declared fresh stdio connection uses source live. Never derive this distinction from receipt wasInserted, origin journal, model state, or a mutable ACK cursor. Missing or contradictory broker attachment metadata rejects startup before consumption. Validate the upstream session against the bound context. Publish the new state and typed reduction only after successful interpretation and a final ownership check. Then explicitly call acknowledgeDurableConsumption on the original delivery. Unknown but valid updates publish unhandled and can be consumed after durable storage. A malformed known update or session mismatch remains stored, blocks the owner, and is not consumed. Later updates are not applied, so missing state cannot fabricate a foreground transition.

No arbitrary asynchronous projection callback belongs in this transaction. Expose state and ordered outcomes through a narrowly scoped observation mechanism that cannot synchronously call arbitrary consumer code between the ownership check and consumption, with bounded diagnostic information referencing journal ordinals rather than retaining another unbounded copy of raw frames. Publication and acknowledgement do not prove UI projection or durable message-row storage. The raw journal is the recoverable source of canonical state.

## End, stop and recovery

Unexpected stream end calls canonical loseObservation for the current context and reports observation loss. It cannot declare foreground completion or upstream rejection. Intentional stop reports stopped without a disconnect-completion effect. Neither path consumes buffered, rejected or in-flight deliveries. Stop is idempotent and cannot close another attachment or erase its journal.

Recovery constructs another owner for the explicitly chosen same source, rebuilds the retained prefix as snapshots and then processes redelivered live handles. A crash after commit but before apply or ACK therefore does not append the event twice. A consumed event rebuilt from history never re-emits a live completion. New direct-stdio connections and broker generations are distinct streams; choosing resume/replay policy between them remains outside this slice.

## Acceptance and validation

Use Swift Testing, real SQLite journal operations, and controllable stream/persistence gates. No fixed sleeps. A new suite is appropriate for this new owner; extend existing transport fixtures where needed.

- Gate the first append and yield multiple deliveries; exact storage and canonical application follow stream order with no early consumption.
- Database failure and stale lease leave state/callbacks unchanged. Detach or ownership replacement during registration, replay or append prevents later publication/consumption, even if storage committed.
- Restart after commit-before-ACK rebuilds snapshots and consumes redelivery once without appending or applying a duplicate. Equal separate chunks both survive.
- Historical running/idle, including previously unjournaled broker backlog through the attachment cursor, does not emit a live foreground completion; subsequent live transitions retain existing lifecycle semantics without advancing a queue.
- Valid unknown updates remain durable/unhandled; malformed known shapes and wrong session IDs block explicitly with retained bytes and no ACK or later application.
- Source/connection/generation mismatch, ordinal gaps, repeated start, intentional stop and unexpected EOF retain their distinct outcomes.
- Incomplete journal prefix stays explicit. No read or replay acquires callback authority.
- Run affected AlasCore suites first, then focused native suites only when app-target runner/persistence seams are touched. Confirm actual test counts, full SwiftFormat lint and whitespace checks. No live adapter or CI claim from fixture results.

## Builder choices and delivery

Exact type names, observation API, bounded diagnostic representation and test seam names are builder choices. Keep one owner, one stream task and the existing journal/state/persistence boundaries. Avoid extending the large v1 runner with a partially usable v2 command path.

Use the established native inline implementation after full design approval, with meaningful RED/GREEN tasks and one fresh final review. Keep changes uncommitted until shipping is requested. Branch nacho/acp-v2-update-owner starts from current merged main; preserve unrelated adapter research.

## Builder check outcome

One fresh builder check found nothing important left after the broker backlog boundary was made explicit. The validated open snapshot already supplies journalTail. Treating previously unjournaled events through that immutable attachment boundary as snapshots is my design choice; it prevents historical idle transitions from becoming new completions. No product code, test execution or commit occurred during design.
