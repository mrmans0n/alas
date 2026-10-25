# ACP lifecycle implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Separate prompt insertion from foreground completion, integrate explicit stop outcomes into v1, and cover v2 lifecycle decisions without activating live v2.

**Architecture:** UI-free wire values preserve raw fields. A deterministic session lifecycle model tracks requests independently of foreground generations. The runner owns transport/persistence and consumes v1 terminal decisions under its existing ownership guards.

**Tech stack:** Swift, Swift Testing, existing AlasCore targets.

**Spec:** [Approved lifecycle design](2026-10-25-acp-v2-lifecycle-design.md), approved with `sgtm`.

## Global constraints

- Live negotiation stays v1. No adapter, broker persistence, replay, or client-tool changes.
- Preserve lease, durable acknowledgment, queue, cancellation, usage-limit, and hydration boundaries.
- Unknown stop outcomes never become success. Only end_turn can trigger successful-turn suggestions.
- Preserve the untracked research note. Keep implementation local until a shipping request.
- Use targeted package tests first, then affected app suites; no entire local test plan.

## Review focus

- An idle snapshot and a repeated idle cannot finish another turn.
- Acceptance may follow a finished foreground interval; it never creates a completion.
- Stop during a prompt response must not cancel or clear the successor.
- A superseded response may record usage but cannot publish completion or suggest another prompt.
- Unknown stop reasons and server-side cancellation must reach parent reports and usage without success wording.

## Task 1: Wire outcomes and deterministic lifecycle

Files: new `AlasACP/ACP/Protocol/ACPSessionLifecycle.swift`, existing `ACPPromptQuota.swift`, `ACPConnection.swift`, and `ACPTurnCompletion.swift`; new package `ACPSessionLifecycleTests.swift`.

Interfaces: `ACPStopReason(rawValue: LSPJSONValue?)` preserves omission/null/unknown values and maps v1 stop outcomes. `ACPV2PromptAccepted` and `ACPV2StateUpdate` decode independently of v1 and retain raw JSON. `ACPSessionLifecycle` exposes request state and emits effects from submitted, v1 terminal, v2 acceptance/rejection, foreground snapshot/live, cancel-requested, and observation-lost inputs. Foreground completions carry a generation and result, never an inferred prompt ID.

- [x] Add a package regression that observes a cancelled v1 prompt response through the connection instead of losing its stop reason. Run it and confirm failure before implementation.
- [x] Add parameterized raw stop-reason, malformed acceptance, and unknown-state fixtures plus ordered lifecycle traces. Assert on effects, request status, and the last foreground outcome.
- [x] Implement the decoders, explicit stopped result, and state model. Keep unknown fields and repeated state handling intact; acceptance and cancellation request alone emit no completion.
- [x] Run focused package lifecycle and negotiation tests using the existing isolated SwiftPM scratch/cache paths. Check actual counts.

## Task 2: V1 runner terminal decisions

Files: `AlasSessions/ACP/Session/ACPSessionRunner.swift`, existing app `ACPSessionRunnerTests.swift` and `ACPSessionRunnerQueueTests.swift`.

Interfaces: connection prompt outcomes carry `stopReason`; terminal publication uses the lifecycle decision and adds `.stopped(ACPStopReason)` to `ACPTurnCompletion.Result`. Existing queue and durable acknowledgment code remains at its current boundaries.

- [x] Add a parameterized runner regression for end_turn, cancelled, bounded/refused, omitted, and malformed reasons. Assert one result and successful-turn eligibility only for end_turn. Observe the regression before editing the runner.
- [x] Track request lifecycle when a normal prompt starts and settle it exactly once on response, failure, or local cancellation. Forget superseded requests at their existing cleanup boundary.
- [x] Use decoded outcomes for response completion and suggestion gating. Keep the completion callback's delivery Boolean distinct from the agent's outcome.
- [x] Extend existing queued completion coverage to verify a stopped response settles the accepted head once and retains successor ownership. Reuse existing cancellation/supersession races.
- [x] Run focused runner/queue/connection suites; inspect actual counts and address regressions.

## Task 3: Reports, usage, and final validation

Files: orchestration policy/coordinator, `AlasModel/Model/ACPDelegatedOutcomeText.swift`, usage store mapping, schedule outcome conversion, and their existing test suites.

Interfaces: stopped/unknown completions produce factual stopped wording and a parent wake, not a successful completion or child retry. Usage stores distinct stopped reason labels; scheduled runs classify these as unsuccessful agent outcomes.

- [x] Add focused regressions for parent disposition/text, usage conversion, and scheduled stop conversion. Confirm the old mapping cannot represent the new outcomes.
- [x] Implement exhaustive mappings for `.stopped`, keeping existing completed/failed/cancelled/limited behavior.
- [x] Run affected package tests first, then app orchestration, usage, schedule, runner, queue, and connection tests with isolated DerivedData.
- [x] Inspect the full diff, run whitespace checks, and request one fresh-context whole-change review. Fix actionable findings with regression evidence.
- [x] Update this plan and the umbrella with completed versus remaining work and exact verification. Do not commit or publish a PR in this slice without a shipping request.

## Implementation result

Implemented on `nacho/acp-lifecycle-model`, based on `9deb125cda60496679767b0ddb31e88ab8a4342f`. Commit and PR publication were subsequently authorized. Workstream 2 of umbrella #2213 remains partial: the v2 decoders and lifecycle decisions are fixture-tested, but production connections still use v1. Live v2 ingress, transcript/replay, broker migration, client integrations, and adapter interoperability remain outside this slice.

Validation on 2026-10-25:

- Package: 23 tests in 3 suites passed: `ACPSessionLifecycleTests`, `ACPProtocolNegotiationTests`, and `ACPDelegatedPromptSourceTests`.
- App: 429 tests across 9 selected suites passed, with 641 executions including parameterized cases, no failures, and no skips. Suites: `ACPSessionRunnerTests`, `ACPSessionRunnerQueueTests`, `ACPConnectionTests`, `ACPPromptQuotaTests`, `ACPSessionOrchestrationPolicyTests`, `ACPSessionOrchestrationCoordinatorTests`, `ACPDelegatedOutcomeTextTests`, `UsageHistoryStoreTests`, and `AppStateRunScheduleTests`.
- The independent review found one actionable issue: server cancellation could be described as user-initiated. A regression observed that failure before the wording changed to neutral cancellation. No other actionable findings remained.
- Existing successful-prompt fixtures now return explicit `end_turn`; omitted and malformed reasons remain covered as unknown outcomes. The first broad run exposed two remaining legacy success fixtures, which were corrected before the final passing run.
- `git diff --check` passed. No repository-wide test plan or live v2 adapter probe ran; CI has not run for this local slice.

Evidence: `/private/tmp/alas-acp2-lifecycle-core-reviewed.log` and `/private/tmp/alas-acp2-lifecycle-reviewed.xcresult`.

Umbrella [#2213](https://github.com/mrmans0n/alas/issues/2213) records these validated foundation steps separately from the full v2 integration checklist, which remains open.
