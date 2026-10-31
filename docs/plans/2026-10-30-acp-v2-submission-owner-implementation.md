# ACP 2 submission owner implementation plan

> **For agentic workers:** Use superpowers:executing-plans with the established native inline method, TDD per task and one fresh final review. No commits until shipping requested.

**Goal:** Prepare actual v2 prompt bindings, persist them before handoff and apply durable outcomes through the existing canonical owner.

**Architecture:** Add a typed transport preparation protocol in AlasACP and submission capability in AlasSessions. The existing owner retains all canonical mutations; persistence uses the existing actor/ledger and live handles remain explicitly consumed only after commit and current-owner checks.

**Tech stack:** Swift, Swift Testing, existing SQLite ledger and transport interfaces.

**Spec:** [Approved design](2026-10-30-acp-v2-submission-owner-design.md).

## Global constraints

- Fixed base 43e0db9f08e1303b692a66d1332652e3599ce9b4, branch nacho/acp-v2-submission-owner. Preserve unrelated research/Ghostty.
- Production stays v1-only. No manager/runner installation, queue/UI, automatic retry, pending adapter requests, permissions, remote cancel, upstream resume or SSH.
- Actual stdio ID or explicit broker operation key/generation is prepared before durable registration. Handoff gate is one-use local authorization, never proof of delivery.
- One canonical owner; latest state is mutated after awaits. RPC failure marks only its attempt uncertain, never rejected or foreground-complete.
- Registration/outcome persistence precedes consumption; stop invalidates gates synchronously. No callback can be reconstructed from storage.

## Files and interfaces

- Create `AlasACP/ACP/Protocol/ACPV2PromptDispatch.swift`: `ACPV2PromptEndpoint` stdio(connectionID)/broker(connectionID,id,generation), `ACPV2PreparedPrompt` with endpoint and binding stdio(requestID)/broker(operationKey), `ACPV2PromptHandoffGate` with invalidate/isValid/claim, and `ACPV2PromptSending: AnyObject, Sendable`.
- Protocol getter `v2PromptEndpoint: ACPV2PromptEndpoint?`; method `sendV2Prompt(_ params: ACPSessionPromptParams, operationKey: ACPBrokerOperationKey?, gate: ACPV2PromptHandoffGate, prepare: @escaping @Sendable (ACPV2PreparedPrompt) async throws -> Void) async throws -> ACPResponse`. Only explicit v2 implementations qualify, no default fallback.
- Extend stdio client for reserved real ID, async preparation and exactly-once pending cancellation; broker client/raw transport for captured endpoint/key and existing exact completion path.
- Extend lifecycle/value owner with `markSubmissionUncertain(requestID:context:)` decision, preserving accepted/rejected state and foreground.
- Create `AlasSessions/ACP/Session/ACPV2SubmissionPersisting.swift`: async register/retain/load-by-id/bounded-page contract; existing persistence actor conforms.
- Extend existing owner with optional `SubmissionCapability(sender:journal:)`, default nil. Add `submit(id:localRowID:params:operationKey:) async throws -> ACPV2SubmissionRecord`, managed per-attempt tasks/gates, bounded restoration and submission observation/effects. An adjacent owner extension may hold submission methods while core lifecycle/update loop stays focused.
- Extend existing stdio/raw broker/owner/lifecycle/state suites. No sibling scenario suites. Temporary app stdio/fake import-adjusted harness is permitted and removed before native checks.

## Review focus

- Cancellation before/after pending installation must settle only the cancelled call, with no late response consumption. Task1.
- Stop before handoff claim prevents dispatch; after claim it only establishes uncertainty. Task1/3.
- Echoes/updates arriving while registration or outcome commit is suspended must survive acceptance application. Task2/3.
- A committed outcome returning to a stale owner must not publish or consume, while recovery can still load its evidence. Task3.
- Multi-page restoration registers acceptances before update snapshots and never sends or mints completion. Task2/3.

## Task1: Actual transport preparation and handoff gate

- [x] Add failing existing stdio tests capturing actual numeric/string ID before enqueue, gated/rejected preparation, cancellation/shutdown before claim, and cancellation after installation with late diagnostics. Add raw broker test capturing fixed endpoint/key before service.send. Observe missing-contract RED.
- [x] Implement typed dispatch values/protocol/gate and additive concrete v2 paths. Stdio cancellation removes/resumes only its pending continuation outside locks. Broker retains existing pending polling/exact outcome selection and explicit key. No v1 call-path changes.
- [x] Run stdio/raw broker/shared RPC suites, inspect actual count, record GREEN. No commit.

## Task2: Canonical submission integration and restoration

- [x] Add lifecycle/state regression for per-attempt uncertainty without changing foreground/accepted facts. Add owner tests for registration-before-dispatch, durable outcome-before-consumption, concurrent reversed responses/echo order and restored ledger before snapshot replay. Observe missing-contract RED.
- [x] Implement persistence protocol/conformance, optional capability, sender validation and managed submission task/gate ownership. Reject already-persisted submission IDs before sender invocation. Add registration and outcome decisions to the latest canonical state only, never a pre-await copy. Distinguish observation effects from reliable per-call result.
- [x] Restore current-filter ledger pages before update replay. Uncertain/error records mark only the registered attempt uncertain; uninterpretable/conflicting evidence blocks visibly. Existing update-only path remains unchanged.
- [x] Run affected package/stdio/broker suites with actual counts and record GREEN. No commit.

## Task3: Failure, cancellation and commit-race evidence

- [x] Extend owner tests with event-gated real persistence at registration/outcome return, stop/ownership loss on both sides of commit, update interleaving, invalid source/upstream, malformed/error/missing raw outcome, stale lease, real SQL failure and conflicting canonical binding. Add restoration beyond128 records and old-source exclusion. Pin any exposed failure with RED before fixing.
- [x] Complete current-owner/blocking fences and conservative uncertainty handling. Stop/blocks cancel managed tasks and unclaimed gates; stale completions cannot mutate or consume. Storage/interpretation conflicts block all further application for that owner, while factual RPC failures remain submission-scoped.
- [x] Consolidate redundant coverage where existing suites pin the same invariant. Run affected selections and record GREEN.

## Task4: Final verification and review

- [x] Remove temporary harnesses. Run final focused package suites, full SwiftFormat lint and tracked/new-file whitespace checks. Attempt focused native stdio/connection/broker validation if feasible; report infrastructure blockers and actual executed counts distinctly.
- [x] One fresh whole-change review against fixed base, including new source/tests/docs. Fix material findings in one RED/GREEN pass, ledger deferred minors and all declined behaviors; no rereview.
- [x] Update umbrella2213, complete plan/ledger, preserve uncommitted branch and unrelated files until shipping requested.

## Preflight and execution rulings

Task1 prepared identity and gate feed Task2 capability; Task2 submission/persistence contracts feed Task3 failure gates. Same module boundaries as approved design, no circular AlasACP→AlasSessions dependency. Existing isolated worktree verified. Retain approved inline method and focused repository checks rather than another execution menu, per-task commits or full-suite default.

## Verification evidence

- Transport preparation RED confirmed missing actual-binding/preparation APIs. Final Task1 selection passed 52 tests/4 suites after correcting the fixture to journal its supplied operation key.
- Canonical integration RED confirmed missing submission capability and per-attempt uncertainty contracts. Task2 selection passed 91 tests/6 suites.
- Commit/lifetime failure matrix and concrete broker integration passed 96 tests/6 suites. Expanded combined selection passed 148 tests/11 suites, including import-adjusted source-identical app stdio tests. Temporary copies were removed.
- Final package selection passed 142 tests/12 suites. Full SwiftFormat lint reported 0/2700 files requiring formatting, 1 skipped. Tracked/new-file whitespace and harness cleanup checks passed.
- Focused native stdio/connection/broker validation is inconclusive. Missing cached dependency manifests stopped package resolution before compilation; completed xcresult summary is unknown with 0 total tests. No build input repairs, native pass, CI or live adapter result is claimed.

Logs: /private/tmp/alas-submission-owner-*.log; native summary: /private/tmp/alas-submission-owner-app-summary.json. Fresh whole-change review is complete; the single material fix pass is described below.

## Final review and correction

The one fresh review found an Important fail-closed scheduling gap and a Minor lease-loss wording overclaim. An event-gated regression reproduced four issues: the canonical owner remained live after discovering a preparation storage failure, and another prompt dispatched and consumed before transport error propagation completed. Terminal storage, canonical-conflict and unsafe-evidence failures now block synchronously at discovery, invalidating gates before another canonical task can run. Pending attempts become uncertain without downgrading acceptance or changing foreground facts.

The post-fix affected package selection passed 143 tests/12 suites, including the new regression. Full SwiftFormat lint again reported 0/2700 files requiring formatting, 1 skipped; whitespace checks passed. The design now distinguishes rejected registration or observed ownership loss before claim from a lease takeover after COMMIT, which cannot atomically revoke remote handoff. No extra database check or atomic remote guarantee was introduced. No second review was run and no findings remain deferred.

Review declined behaviors are retained as designed: cancellation after claim may leave uncertainty; latest-state mutations and provenance are fenced at existing local boundaries; restoration is passive; same-key broker polling preserves the existing path. Manager installation, retry, permissions, SSH, outgoing lossless encoding and production v2 rollout remain excluded. Unrelated Ghostty/research inputs remain untouched. Native validation remains unverified for the dependency-cache reason above. Shipping was requested after verification. Related changes are prepared for commit and PR; unrelated Ghostty and research inputs remain excluded.
