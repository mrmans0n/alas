# ACP v2 ordered session state implementation plan

> **For agentic workers:** Use superpowers:executing-plans for the established native inline workflow, with one final fresh-context review.

**Goal:** Compose canonical v2 messages, activity, prompt outcomes, and foreground state behind one context-fenced owner.

**Architecture:** Add exact lifecycle wire entry points and a shared bounded integer decoder, then a synchronous `ACPV2SessionState` containing the existing reducers. Results retain raw inputs and ordered effects; no live transport, storage, or UI owner is installed.

**Tech stack:** Swift, Swift Testing, existing AlasACP target.

**Spec:** [Approved design](2026-10-26-acp-v2-session-state-design.md).

## Global constraints

- Fixed baseline `ce0093d4929d3460305ac4fb0c40b4f5125ac1d2`; no mid-validation rebase.
- Keep all live eligibility v1 and the Debug preference default-off. No transport, queue, lease, ACK, UI, storage/replay, permission, or execution-host changes.
- Preserve raw opaque numbers and unknown fields through explicit wire entry points. Generic Decodable stays available with its documented numeric limits.
- Known required/interpreted malformed values fail before mutation; optional malformed error details remain raw without hiding valid foreground state.
- Context and session guards precede every mutation. Separate entity types share no identity, and acceptance never implies foreground completion.
- Keep implementation, ledger, and review artifacts local until shipping; preserve the existing untracked research note. Use `/private/tmp` for execution artifacts and isolated package caches.

## Review focus

- A response whose message binding conflicts must not leave either lifecycle accepted or a different local row bound.
- A default ignored after an observed state, including after observation loss, must not replace the retained observation or imply idle.
- A tool can introduce several terminal placeholders among interleaved messages without moving previously observed keys.
- Failure data containing unrepresentable numbers must not hide its valid message or change exact numeric tokens.
- Stale registration, response, rejection, update, and observation-loss calls must leave all child state and ordering unchanged.

## Task 1: Lossless lifecycle inputs

Files: extract v2 wire structs from `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPSessionLifecycle.swift` into `ACPV2LifecycleInput.swift`; create `ACPWireInteger.swift` there and reuse it in `ACPV2ActivityUpdate.swift`; extend `Packages/AlasCore/Tests/AlasCoreTests/ACPSessionLifecycleTests.swift`.

Interfaces: `ACPV2PromptAccepted` and `ACPV2StateUpdate` add `decode(from: Data)`, `init(rawValue: LSPJSONValue)`, and `encodedData()`. State exposes exact `failure` details with Int32 code, message, optional raw data, and raw object; existing `error` remains a Foundation-compatible convenience. `ACPWireInteger.decode(_:as:) -> T?` normalizes only valid exact integral tokens within a fixed-width type's bounds.

- [x] Add `lifecycleWireInputsKeepOpaqueNumbersAndFailureMessages`, `malformedLifecycleWireContainersAreRejected`, and parameterized signed error-code boundary/optional-malformation tests in the existing lifecycle suite. Assert exact raw round trips, useful failure message for `1e999` data, explicit malformed stop reasons, and fallback for invalid optional details.
- [x] Run `ACPSessionLifecycleTests` with the existing isolated SwiftPM paths. Expected RED: missing explicit wire APIs/failure view.
- [x] Implement the wire entry points and compatible generic decoding, exact signed/unsigned numeric helper reuse, and Equatable state provenance. Preserve v1 lifecycle and error decoding behavior.
- [x] Run lifecycle/message/activity/negotiation suites. Expected GREEN with actual executed counts; existing uint32 cases still pass.

## Task 2: Ordered notification owner

Files: create `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPV2SessionState.swift`; extend the envelope payload/dispatch in `ACPV2SessionUpdateEnvelope.swift`; update unknown fixtures in `ACPV2MessageTranscriptTests.swift`; create `Packages/AlasCore/Tests/AlasCoreTests/ACPV2SessionStateTests.swift`.

Interfaces: `ACPV2SessionState(context:)` exposes read-only `transcript`, `activity`, `.v2` `lifecycle`, combined `order`, and `latestStateObservation`. `apply(_:source:context:) throws -> Reduction` returns original event, disposition, and effects wrapping message/activity/lifecycle effects. Invalid setup-default provenance throws before mutation; stale context returns stale. Combined `Key` separates message kinds, tools, plans, and terminals.

- [x] Add interleaved equal-ID ordering, terminal-reference ordering/removal, state/raw-event dispatch, latest repeated observation, unknown/stale no-op, and explicit snapshot/default/loss-boundary tests. Assert no synthetic row or completion and no invalid-default mutation.
- [x] Run the owner suite. Expected RED: missing owner contract.
- [x] Implement exactly-once routing, append-only first-observed entity order, typed state payload, explicit provenance validation, and latest-applied observation. Promote malformed old state-update unknown fixtures to genuinely unknown variants.
- [x] Run owner/lifecycle/message/activity/negotiation suites. Expected GREEN with actual counts; message accessor and patch behavior remain compatible.

## Task 3: Atomic registration, outcomes, and observation loss

Files: extend the owner and its existing suite.

Interfaces: `register(requestID:localRowID:context:)`, `accept(requestID:response:context:)`, and `reject(requestID:context:)` return `SubmissionReduction` with original optional acceptance, explicit disposition, and effects. `loseObservation(context:) -> [Effect]` retains canonical state/correlation and reports lifecycle decisions only. Retain request registrations for this context's lifetime.

- [x] Add both echo/accept orders and identical submissions with reversed responses, conflict rollback across both models, stale operations, duplicate outcomes, accepted-versus-rejected contradiction, rejection during active work, acceptance before/after idle, and observation loss with pending and accepted requests. Reconciliation/message-change effects must precede accepted lifecycle effect.
- [x] Run the new prompt tests before production methods. Expected RED: absent outcome APIs. Retain a behavioral regression proving a conflict cannot partly bind before committing trial child states.
- [x] Implement atomic outcome validation/commit, context guards, retained correlations, and observation loss without retries or invented completion.
- [x] Run all five affected suites with isolated scratch/cache paths; inspect actual counts. Run full SwiftFormat lint and whitespace checks for all tracked/new scoped files.
- [x] Obtain one fresh final review against the fixed baseline and full new-file manifest. Re-grade findings, fix material issues with RED/GREEN evidence, and do not dispatch a second review.
- [x] Record results/rulings in this plan and local ledger. Update #2213 with locally validated work and deferred integration; keep changes uncommitted until shipping.

## Result

Implemented on `nacho/acp-v2-session-state`, based on `ce0093d4929d3460305ac4fb0c40b4f5125ac1d2`. Publication was authorized on 2026-10-26. The pre-existing research note is excluded.

- Exact lifecycle wire inputs preserve opaque numeric tokens and optional malformed failure data. A valid failure message survives opaque data outside Foundation's numeric range. Existing generic decoding remains available with its documented limitations.
- The new synchronous owner composes existing message/activity/lifecycle reducers, preserves combined entity order, and atomically reconciles prompt insertion outcomes. Stale calls and contradictory outcomes cannot partly mutate either child.
- Explicit provenance keeps setup defaults, current-state snapshots, repeated observations, and observation loss separate from new foreground completion. Live transport, projection, durable storage/replay, broker delivery, adapter adoption, and rollout remain pending.
- Final validation passed 66 tests in 5 suites: `ACPV2SessionStateTests`, `ACPSessionLifecycleTests`, `ACPV2MessageTranscriptTests`, `ACPV2ActivityStateTests`, and `ACPProtocolNegotiationTests`. One overlapping decoder test was merged into the existing identity-validation test.
- Full SwiftFormat lint reported `0/2644 files require formatting, 1 file skipped`. Tracked/new-file whitespace checks passed.
- Independent final review inspected all 11 scoped files and the strengthened original-input retention assertions, and found no actionable issues. No app build, CI, or live interoperability result is claimed.
- [Umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) tracks this foundation alongside the remaining live integration, whose full checklists stay open.

Final evidence is local in `/private/tmp/alas-acp2-session-reviewed.log` and `/private/tmp/alas-acp2-session-format-reviewed.log`. The execution ledger and review package remain in `/private/tmp` until shipment.
