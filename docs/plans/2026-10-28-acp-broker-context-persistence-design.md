# Persisted ACP broker context and restore boundaries

Status: approved with "sgtm" on 2026-10-28. One fresh read-only builder check returned "nothing important left".

## Intent

Complete the persisted connection identity boundary before connecting the raw-v2 transport to the runner. The merged transport exports `ACPBrokerDurableState.wireContext`, but `ACPSessionPersistence.updateACPBrokerState` currently drops it, and `ACPSessionManager.makeBrokerConnection` always creates the default legacy-v1 client. Persisted raw-v2 state must never be reopened as structured-v1 traffic or automatically replaced when the current runner cannot handle it.

This is the next focused slice of umbrella #2213. PR #2241 merged at `d9be8370c9beaede1b4e62a96652839c905bf400`; its final implementation head was `a011b48f04474a4163093786f62aa7e8eb9eccdf`. Repository reconnaissance refreshed main to `cdd3a5f7a`. The current schema version on main is 29. Recheck migrations at implementation time.

## Goals and acceptance boundary

Persist broker ID, generation, wire context and acknowledged cursor as one coherent connection descriptor. Keep existing v1 restore and metadata-upsert behavior working. Preserve unknown or malformed persisted context as evidence and fail explicitly when attachment needs to interpret it.

Install a restore decision before any helper/service handoff, adapter initialization, queue dispatch, automatic restart/close, isolated fallback broker creation, or destructive recovery-state reset. Current production support remains v1 only, regardless of the Debug toggle. A saved raw-v2 broker therefore produces an actionable unsupported-restore error and leaves its state intact. A future caller with installed v2 support can resolve the same descriptor without changing this persistence format.

This slice does not install a raw-event journal, the v2 runner/session-owner bridge, transcript projection, foreground completion/queue changes, SSH raw transport, cross-version upstream session conversion, adapter eligibility, or helper publication. Those remain follow-ups. Saving a broker cursor is not a claim that v2 transcript events have been durably stored.

## Persisted representation

My recommended representation is one nullable TEXT field on `sessions`, `acp_broker_wire_context`, containing the existing `ACPBrokerWireContext` JSON object. Add an additive migration using the existing guarded migration conventions; do not rewrite prior databases or replace the store. Use the next schema version available on the implementation base.

The persisted row must retain the original stored string when it is unknown or malformed. Do not decode it with `try?` and substitute nil, v1, a default version, or a supported context. A typed accessor/resolver can distinguish absent, recognized and unsupported/malformed context. A wrapper type versus a raw-string field plus strict resolver is left to the builder, provided opaque storage and the public read/write APIs retain those distinctions.

Interpret absence only as the existing legacy-v1 compatibility case. A row without a broker binding keeps its current no-broker behavior. Preserve existing legacy rows that have a preselected broker ID but no generation yet; do not invent a v2 generation or ACK cursor for them. An explicit raw-v2 descriptor requires a valid broker ID and positive generation. Invalid context/identity combinations and out-of-range values block attachment with an error; do not silently normalize them into a fresh v1 session. Cursor zero remains valid.

Keep this field in `ACPSessionRow` and all applicable row-to-store, hydration, manager cache and mirror/metadata-copy paths. A mirror may display retained session data without interpreting or attaching to an unsupported broker.

## Mutation and ownership rules

Thread `state.wireContext` through `ACPSessionPersistence` into the store. A durable connection-state write persists the full descriptor together under the existing SQLite transaction/lease fence. Manager in-memory rows and recent-row snapshots use the same identity comparison as storage, including context. An unchanged ID/generation cannot change its wire context. Reject that mismatch before writing any part of the tuple or advancing its cursor.

Cursor-only updates must match broker ID, generation and the effective stored context. Keep monotonic cursor updates within that identity, and reject a stale/mismatched context or generation without mutation. Existing NULL context compares as legacy-v1; an explicit legacy write may canonicalize that absence when establishing a validated descriptor. Unknown/malformed context is never an ACK match.

Changing broker generation through the existing explicit validated connection-state path may reset its cursor and establish the new generation's context. Keep current callback-owner/connection-owner and writer-lease checks; a late callback from an old attachment must not overwrite a successor's descriptor. Do not broaden this slice into a new ownership protocol.

Ordinary session metadata upserts must preserve a stored context when the snapshot omits broker information. Preserve existing legacy upsert rules for same-generation monotonic cursors and genuine generation changes, extending their identity comparison to include context. A metadata snapshot cannot erase raw/unknown context, combine fields from incompatible descriptors, or silently convert an existing raw binding into legacy because the new field defaults to nil. For raw/unknown bindings, preserve the stored tuple when incoming metadata lacks or contradicts its context; establishing/replacing that binding goes through the explicit validated state writer. Continue unrelated metadata updates rather than discard the opaque context or prevent a title edit.

The existing explicit clear operation clears broker ID, generation, context and cursor together, with its current lease behavior. It does not clear messages, the upstream session ID or queued prompts, and it is not permission for a cross-version resume. An unsupported restore never invokes it automatically.

## Restore decision and integration

Add a small UI-free restore resolver near the existing ACP connection/row domain. Inputs include the persisted descriptor and the caller's actually installed supported versions. Its outcomes distinguish no existing broker, a recognized restorable descriptor, and a typed blocking error with the original context retained. The live manager supplies `ACPProtocolSelection.supportedVersions`, which currently contains only v1. Fixtures can supply v2 explicitly to verify raw descriptor resolution without making production v2 eligible.

A stored descriptor is authoritative for its running generation. Current preference changes apply only to new connections and cannot reinterpret a saved broker. Capture the resolved descriptor for one attachment attempt; do not reread a mutable preference halfway through it. For allowed legacy restores, use its generation/cursor exactly as today. Future allowed raw restores must pass `.rawV2` and the saved expected generation to the low-level broker client; no such live factory is enabled in this slice.

Place the blocking decision at the shared attachment/recovery boundary, early enough that fallback branches cannot bypass it. Incompatible or unrecognized persisted context is not an agent runtime/authentication failure, a missing process, or evidence the upstream session ended. Surface an actionable message through the existing error path, such as that this saved connection needs ACP2 runner support and its broker/history were preserved. Do not automatically close, retry as v1, spawn a fallback broker, replay a queued prompt, clear the saved descriptor, or move into transcript/context transfer as a workaround.

The early gate must cover manager restore/restart entry points and remote authority acquisition, which can run before `makeBrokerConnection`. A restart of an unsupported saved connection must not begin teardown and then discover that it would reinterpret its upstream session. This adds no new reset/conversion action; the explicit store clear API remains available under its existing ownership contract.

Preserve existing cancellation and writer/mirror checks. Unknown context may coexist with readable persisted session metadata; blocking attachment must not archive the session or erase its history. Direct-stdio and SSH sessions with no broker binding remain unchanged. This slice does not teach the SSH helper-proc transport to consume raw broker context.

## Code pointers

- Row and connection domain: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPSessionLease.swift`, `ACP/Protocol/ACPProtocolVersion.swift`, `ACP/Broker/ACPBrokerClient.swift`.
- Context codec: `Packages/AlasCore/Sources/AlasPlatform/SSH/ACPBrokerWireContext.swift`.
- Store: `Packages/AlasCore/Sources/AlasSessions/ACP/Session/ACPSessionStore.swift`, especially migrations, `upsertSession`, `rowToSession`, broker state/cursor writers and clear.
- Persistence: `ACPSessionPersistence.swift` in that directory; hydration/copy readers must retain the new row field.
- Manager: `Packages/AlasCore/Sources/AlasAgents/ACP/Session/ACPSessionManager.swift`, especially `persistACPBrokerState`, `makeBrokerConnection`, restore/recovery fallback and callback-owner guards.
- Tests: existing `ACPSessionStoreTests`, `ACPSessionStoreCRUDTests`, `ACPSessionPersistenceTests`, `ACPSessionManagerAttachRestoreTests`, `ACPSessionManagerRemoteRestoreTests` and broker negotiation suites. Extend existing suites where the behavior belongs.

## Validation

Use test-first regressions for these boundaries, consolidating related cases rather than expanding a broad test matrix:

1. Migrate an existing schema-29 database with legacy broker state; ID/generation/cursor and session data survive, and absence resolves to v1. Verify new-store and repeated-open behavior through existing migration coverage.
2. Persist and reload explicit legacy/raw contexts through row/store/persistence and relevant cache/hydration paths. Unknown/malformed stored context survives a metadata upsert byte-for-byte and produces an explicit restore error.
3. Metadata snapshots cannot erase or cross-mix a raw descriptor. Same-identity cursor updates remain monotonic; mismatched context, generation and stale lease writes change nothing. Explicit clear resets the complete descriptor without erasing conversation/queue data.
4. A same-generation context switch is rejected atomically. A deliberate validated new-generation state write installs its context and new cursor together, subject to existing owner/lease checks.
5. A raw descriptor resolves under fixture-installed v2 support, retaining expected generation/cursor. Under current production support, with the Debug preference both off and on, it fails before open/close/send/ACK or any recovery/fallback mutation. Unknown or partial raw descriptors obey the same no-side-effect rule.
6. Existing v1 restore, including old NULL-context rows, legacy broker restart rules, direct-stdio recovery and untouched remote paths, retains its established behavior. Cancellation/late callbacks cannot overwrite the current descriptor.

Run affected AlasCore tests first, then focused app store/persistence/manager suites where their integration is tested. Use temporary databases and existing in-memory broker fixtures. Avoid fixed sleeps and the full local app test plan. Inspect actual selected counts. Run formatting and whitespace checks. Update umbrella #2213 with exact local evidence and remaining integration gaps; do not claim live adapter, CI or SSH behavior from fixtures.

## Work and handoff

Use the established written plan plus inline implementation workflow after approval. Work on a fresh feature branch based on current main in the existing isolated worktree, preserve the unrelated adapter research note, and keep commits/PR creation for a separate shipping request. Use one fresh final review and regression-backed material fixes. No product code or migration has been changed while preparing this design.

Builder-owned choices are helper names, raw-string wrapper shape, precise early guard placement and test organization within the existing package boundaries. The persistence semantics, production v1 gate, no-side-effect rejection and deferred scope above are requirements rather than optional implementation details.
