# ACP broker context persistence implementation plan

> **For agentic workers:** Use superpowers:executing-plans with native inline execution and one fresh final review. The established execution method and approved full design are retained.

**Goal:** Retain broker wire context durably and block incompatible restores before side effects.

**Architecture:** Preserve the exact optional stored context JSON on ACPSessionRow, expose strict UI-free restore decisions, and extend the existing SQLite broker descriptor writes and manager attachment boundaries. Production remains v1-only.

**Tech stack:** Swift, Swift Testing, SQLite, existing lease and attachment ownership.

**Spec:** [Approved design](2026-10-28-acp-broker-context-persistence-design.md).

## Global constraints

- Base `4224313ad432ee1d5362747d70699b803396e814`; branch `nacho/acp-broker-context-persistence` in the existing isolated worktree. Preserve unrelated research. No task commits or PR until shipping is requested.
- One nullable TEXT column `acp_broker_wire_context`; preserve unknown/malformed strings verbatim. NULL remains legacy-v1 compatibility only.
- Persist ID/generation/context/cursor coherently; same-generation context switches and stale ACK/lease writes cannot mutate state. Existing legacy upserts remain compatible.
- Block unsupported restore before helper access, fallback, restart teardown, remote authority acquisition or recovery reset. Keep production eligibility v1-only, regardless of preference.
- No raw journal, v2 runner/UI activation, SSH raw transport, adapter/deployment changes or cross-version session conversion.

## Review focus

- Metadata upserts omit or contradict context while another attachment owns a raw descriptor; preserve its entire tuple, including opaque context.
- Lease-fenced store operations already own a transaction; do not introduce nested BEGIN, read/write races or partial mutations.
- Incompatible saved context reaches restart, remote authority, isolated broker or transcript-transfer fallback; no helper/recovery side effect is allowed.
- Same broker generation arrives with changed context; reject before manager caches, recent rows or SQLite diverge.
- Legacy ID-only rows and NULL contexts remain usable; malformed/partial raw descriptors never become fresh v1 launches.

## Task 1: Persisted row contract and restore policy

Files: `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPSessionLease.swift`; new adjacent `ACPBrokerRestorePolicy.swift`; new package `ACPBrokerRestorePolicyTests.swift`.

Interfaces: add `ACPSessionRow.acpBrokerWireContextJSON: String? = nil`, with initializer default. `ACPBrokerRestorePolicy.resolve(row: ACPSessionRow?, supportedVersions: Set<ACPProtocolVersion>) throws -> ACPBrokerRestoreDescriptor?`. Descriptor contains brokerId, optional generation, cursor and known wireContext. `ACPBrokerRestoreError` retains raw context in invalid/unsupported cases and has actionable descriptions. `ACPBrokerWireContext.persistedJSON() throws -> String` writes canonical controlled context.

- [x] Write parameterized resolver tests for NULL/legacy ID-only, explicit raw with v2 installed, v1-only support under both Debug preferences, unknown/malformed contexts and invalid partial raw descriptors. Assert exact descriptor/error and retained original JSON.
- [x] Run `swift test --package-path Packages/AlasCore --filter ACPBrokerRestorePolicyTests` with isolated existing cache paths. Expected RED: missing public contract.
- [x] Implement strict resolver and row field. Known unsupported context is distinct from malformed context; no normalization via try?. No binding with all fields absent resolves nil; broker ID-only legacy resolves its namespace with nil generation/cursor0. Invalid IDs, nonpositive bound generation, negative cursor, context without identity and raw without generation fail.
- [x] Run affected package restore, negotiation and broker contract suites. Expected GREEN with actual selected counts.

## Task 2: Context-preserving SQLite and persistence ownership

Files: `ACPSessionStore.swift`, `ACPSessionPersistence.swift` under AlasSessions/ACP/Session; applicable row copy/hydration readers; extend existing app ACPSessionStoreTests/CRUDTests and ACPSessionPersistenceTests.

Interfaces: schema30 if still next available; add column and row decoder/insert binding. Extend `updateACPBrokerState(..., wireContext: ACPBrokerWireContext = .legacyV1)` and `updateACPBrokerAcknowledgedCursor(..., wireContext: ACPBrokerWireContext = .legacyV1)`. Persistence forwards state.wireContext. Existing explicit clear clears the new field.

- [x] Add failing migration/store regressions: old29 preserves legacy descriptor; raw and opaque strings survive metadata-only/conflicting upserts; matching cursor monotonicity; context/generation mismatches unchanged; validated generation replacement; full clear retains conversation data. Extend existing tests rather than duplicate their cases.
- [x] Add a persistence lease-fence regression proving raw context round-trip and stale-owner rejection. Run package tests first, then focused app store/persistence suites; expect absent-column/contract or wrong behavior RED.
- [x] Implement additive migration, descriptor writes and metadata upsert rules. Use atomic SQL guards/CAS where validation reads state; do not start a nested transaction inside an existing lease fence. Unknown contexts never match ACK. Existing raw/opaque tuple wins over omitted/conflicting metadata while unrelated metadata still updates. Preserve legacy generation-change behavior.
- [x] Run affected package and focused app store/persistence suites, including existing broker cursor and lease tests. Expected GREEN with actual selected counts and no migration data loss.

## Task 3: Manager restore, restart and callback gates

Files: `Packages/AlasCore/Sources/AlasAgents/ACP/Session/ACPSessionManager.swift`; extend existing AttachRestoreTests, RemoteRestoreTests and relevant lease/restart suites.

Interfaces: use Task1 policy at shared attach/restart/authority entry points; keep one captured descriptor per attachment attempt. Existing manager durable-state callbacks forward context and compare the same full identity before updating cached rows. Broker factory receives resolved generation/cursor/context only after the gate.

- [x] Add failure traces using existing manager fixtures: saved raw or malformed context blocks attach/restart before broker/service/remote claims and before queue/recovery changes; assert original descriptor/history retained. Parameterize preference off/on. Existing legacy/no-broker paths remain covered by their existing suites.
- [x] Add callback ownership/context mismatch assertion at the existing fixture boundary; same-generation conflicting context cannot change memory/store while a valid new descriptor retains its context.
- [x] Run package tests then selected manager tests. Expected RED: service/fallback/teardown occurs or context disappears.
- [x] Install strict early gate with existing error presentation, covering public writer acquisition and remote authority routes as well as attach/restart. Revalidate freshly loaded row where needed after awaits; preserve owner/lease checks. Capture resolved legacy descriptor for broker creation, do not enable raw factories or eligibility. Persist callback context coherently; no automatic clear/fallback on typed context errors.
- [x] Run affected package/store/persistence/manager suites. Expected GREEN; inspect test counts, keep evidence limits explicit.

## Task 4: Review and tracking

- [x] Run final affected package/app tests, full SwiftFormat lint and whitespace checks; no full app plan. Confirm v1 eligibility unchanged.
- [x] Dispatch one fresh read-only final review against the fixed base plus complete untracked manifest. Fix material findings with RED/GREEN and one fix pass; ledger all rulings/deferred minors, no rereview.
- [x] Complete this plan and execution ledger; update #2213 with exact evidence and deferred journal/runner/live scope. Keep work local and uncommitted until shipping.

## Execution notes

- All implementation, review, native verification and umbrella evidence steps are complete. Work remains local and uncommitted as approved.
- Resolver RED/GREEN: missing contract, then 15 tests/3 suites passed. Store/persistence source-identical SwiftPM harness passed 70 tests/4 suites. New manager fixture traces failed with 21 observable issues before the guards and passed afterward.
- Fresh whole-change review found 3 Important issues: queued metadata reverting a new legacy generation, detach missing an awaiting restart, and remote takeover failing to validate its fresh row. All 3 reproduced in focused regressions with 7 observable failures. The single fix pass passed 30 tests/6 suites; no second review and no deferred minor findings.
- Manager metadata writes now opt into preserving the existing broker descriptor, while direct store callers retain legacy generation-change compatibility. Dedicated durable-state writes own context/generation replacement. Metadata CAS still protects concurrent descriptor changes.
- Restart validation has a detach-visible token. Takeover validates its fresh row before remote seize and checks its token after writer confirmation. The cancellation fixture covers both attach and restart using events, without fixed sleeps.
- Final package selection passed 46 tests/7 suites. Full SwiftFormat lint reported 0/2659 files requiring formatting, 1 skipped. Temporary app-source harnesses were removed. The earlier native builds changed underneath compilation and failed on stale test-hook interfaces; they are not test passes.
- Production version eligibility remains v1-only. Raw-event durability, runner/UI integration, SSH transport, adapter publication/deployment and live v2 interoperability remain outside this slice.

## Execution rulings

- Keep the already-approved inline execution method rather than add another method-selection approval. If the decomposition proves wrong, adjust it without changing the approved semantics.
- Keep the optional original context JSON on the row and use a strict resolver. The cost is one raw-string field retained for diagnostics instead of an enum-only row.
- Use temporary source-identical store/persistence suites and exact manager fixture extracts through SwiftPM for rapid RED/GREEN checks. Remove them before final validation. Their limitation is that app-target integration requires the separate native run.
- Reread persisted descriptors at side-effect entry points after awaits; each created client retains its immutable resolved context. The cost is extra local SQLite reads/flushes during attachment.
- Register local attachment/takeover/restart validation identity before suspension, while deferring helper/lease/remote/teardown side effects until validation passes. Blocked requests briefly exist in manager bookkeeping so detach can cancel them.
- Preserve existing broker state on manager metadata upserts while keeping direct store legacy behavior. Callers intending to replace a broker must use the explicit validated durable-state writer.

The first stable native run executed 279 definitions / 356 parameterized executions; 277 definitions passed. Two new fixtures needed synchronization: the callback fixture now acquires a writer lease, and the remote setup publication is drained/stopped before counting blocked calls. The three material review regressions passed in that run. The final six-suite rerun passed; production code did not change for these fixture repairs.

## Final evidence

- Final native xcresult: **Passed, 279 definitions / 356 executions across all six selected suites, zero failures or skips**. Store schema/migrations, CRUD, persistence, manager attach/restore, remote restore and leases all passed. Result: `/private/tmp/alas-context-app-verified.xcresult`.
- Final package check: **46 tests in 7 suites passed**. Log: `/private/tmp/alas-context-package-reviewed.log`. Callback context/cache fixture confirmation also passed independently.
- Full SwiftFormat lint: **0/2659 files require formatting, 1 skipped**. Tracked diff and all four new files pass whitespace checks. Temporary app-source harnesses were removed.
- [Umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) records this as locally implemented, pending commit/PR/merge, with CI and live ACP2/SSH results explicitly unclaimed.
- Branch `nacho/acp-broker-context-persistence` and worktree are preserved. No commit, push or PR was created. The approved plan's keep-local choice takes precedence over the generic finishing workflow's integration menu and full-suite suggestion; repository policy calls for focused local suites.
