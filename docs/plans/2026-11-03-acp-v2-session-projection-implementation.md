# ACP v2 session projection implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Project canonical v2 transcript and activity into an explicitly owned ACPSession without enabling production v2.

**Architecture:** Add synchronous ordered canonical publications to the existing owner, forward them through runtime/bootstrap, and consume them in an epoch-bound MainActor bridge. Project supported values into existing transcript rows and keep exact typed v2 values alongside them. Preserve original journal, ACK and lifecycle authority.

**Tech stack:** Swift, Swift Testing, existing AlasCore targets and ChangeTracking APIs.

**Spec:** `docs/plans/2026-11-03-acp-v2-session-projection-design.md`, approved in conversation.

## Global constraints

- Production remains v1-only; no manager/runner installation, queue dispatch, request execution, new UI or schema.
- Preserve unrelated `ThirdParty/ghostty` and `docs/research/2026-10-25-acp-v2-adapter-support.md` changes.
- No new ingress or observation-stream consumers. Status streams remain latest-only.
- Canonical publications follow mutation and required COMMIT; ACK requires current authority after external callbacks.
- Snapshot/setup-default state cannot publish live completion. Acceptance is insertion evidence only.
- Unknown content and exact terminal output stay typed and inspectable. Agent terminal display never creates process authority.
- Keep implementation in UI-free packages. No legacy v1 decoder or replay heuristics, no legacy row persistence.
- Follow the established inline workflow: no interim commits; one fresh final review and one combined material fix pass. No rereview. Commit/PR only when requested.
- Leave #2213 unchanged without separate explicit authorization.

## Review focus

1. Reentrant ChangeSignal observers can replace the destination before an array setter finishes. Task 2 tests the actual transcript mutation seam.
2. Accepted local rows can arrive before or after canonical echoes. Task 2 parameterizes both orders and preserves local metadata.
3. Several foreground intervals can occur before any latest-only observer runs. Tasks 1 and 3 require every ordered notification.
4. Setup default, replay and local uncertainty have different durability and lifecycle authority. Tasks 1 and 3 preserve provenance.
5. Terminal byte output and unsupported content cannot survive a lossy legacy conversion alone. Tasks 2 and 3 assert exact typed evidence.

## File responsibilities

All source paths below are under `Packages/AlasCore/Sources/AlasSessions/ACP/Session/` unless stated otherwise.

- Modify `ACPV2SessionUpdateOwner.swift`: typed canonical publication, callback and post-callback fences.
- Modify `ACPV2AttachmentRuntime.swift`, `ACPV2SessionBootstrap.swift`: optional callback forwarding and typed projection failure propagation.
- Create `ACPV2SessionProjection.swift`: installation ownership, incremental row mapping, typed projected state and ordered notifications. Keep conversion helpers private here unless they become independently substantial.
- Modify `ACPSession.swift`: optional typed projection value and exclusive epoch reservation, without automatic installation.
- Modify `ACPTranscript.swift`: smallest atomic/guarded mutation seam required by real reentrant observer behavior; preserve existing v1 callers.
- Extend `ACPV2SessionUpdateOwnerTests.swift`, `ACPV2AttachmentRuntimeTests.swift`, `ACPV2SessionBootstrapTests.swift` for their boundaries.
- Create `Packages/AlasCore/Tests/AlasCoreTests/ACPV2SessionProjectionTests.swift` for bridge behavior. Do not create scenario-sliced sibling suites.

## Task 1: Ordered canonical publications

**Interfaces**

Add nested public `ACPV2SessionUpdateOwner.CanonicalPublication` with `revision: UInt64`, `context: ACPV2SessionState.Context`, `change: Change`, and `state: ACPV2SessionState`.

`Change` is a nested Sendable enum:
- `update(Application)` for journal applications, retaining ordinal/source/effects.
- `submission(SubmissionApplication)` for retained/replayed submissions and locally registered attempts; retain explicit provenance using a nested `SubmissionSource` enum with `registration`, `snapshot`, `live`, `localUncertainty`.
- `setupDefault(ACPV2SessionState.Reduction)`.
- `observationLost([ACPV2SessionState.Effect])`.

Submission provenance may be stored beside SubmissionApplication in the enum case rather than changing existing status payloads. No durable status is implied by registration/local uncertainty. Add optional `onCanonicalChange: (@MainActor (CanonicalPublication) throws -> Void)? = nil` to owner initialization. Its publication revision starts at 1 and is independent of existing status revisions. No callback is emitted for a no-op status publish alone.

- [x] Write owner regressions `canonicalCallbacksObserveCommittedChangesInOrder` and parameterized `canonicalCallbackLossPreventsConsumption`. Feed live frames and real SQLite storage, assert monotonically contiguous publication revisions, committed record visibility inside callback, and zero consumption when callback stops the owner or throws. Include several running/idle intervals without reading observations.
- [x] Run `rtk swift test --package-path Packages/AlasCore --filter ACPV2SessionUpdateOwnerTests` with the established isolated caches/scratch runner if needed. Confirm nonzero selected tests and a missing-contract/behavior RED.
- [x] Implement the publication type and synchronous callback at every canonical mutation site: update replay/live, submission registration/recovery/acceptance/local uncertainty, setup default, and observation loss. Callback errors become a typed owner `Failure.projection(message: String)` and terminate current work. Recheck ownership after callback before ACK, next mutation or command success. Preserve the terminal cause if callback reentrantly stops the owner.
- [x] Add snapshot and setup-default assertions to the same tests. Replay has snapshot provenance; setup default and uncertainty have explicit local provenance; terminal loss is published once. Exercise a callback that cancels an initiating submission before handoff.
- [x] Run the affected owner suite GREEN and inspect the actual test count. Record results; do not commit yet.

## Task 2: Epoch-bound session projection

**Interfaces**

Create `@MainActor public final class ACPV2SessionProjection`:

- `init(session: ACPSession, upstreamSessionId: String, connectionID: UUID, optimisticRowIDs: Set<UUID> = [], isCurrent: @escaping @MainActor () -> Bool, onChange: (@MainActor (Notification) -> Void)? = nil) throws`.
- `func apply(_ publication: ACPV2SessionUpdateOwner.CanonicalPublication) throws`.
- `func stop()` synchronously withdraws only its own epoch.
- `Notification` carries revision, provenance and ordered effects, including explicit live completion facts. It grants no execution/queue authority.
- `Failure`: invalidDestination, invalidContext, revisionGap, conflictingIdentity, invalidated.

Add `public private(set) var v2Projection: ACPV2SessionProjection.State?` on ACPSession and narrow internal reservation/update/release methods. `State` holds epoch/context, foreground, observation availability, latest completion, typed canonical entities/order and submission facts. Preserve all raw values in canonical structs; existing row formatting is secondary. It may share canonical state value storage rather than duplicating raw payloads.

Require a destination with no legacy runner projector reservation and no unrelated rows. Add explicit internal legacy reservation only if existing runner ownership can otherwise coexist with this opt-in installation; do not claim that `agentState == idle` proves exclusive ownership. Permit only supplied optimistic UUIDs, validated as unique user rows. A subsequent installation must invalidate the previous epoch and satisfy destination rules; it cannot adopt old rows by text. A bridge cannot clear a successor's state.

- [x] Write `projectionKeepsCanonicalOrderAndStableRows` with message append/replace, mixed tool/plan order and unchanged duplicates. Assert stable UUIDs, canonical positions and no repeated rows.
- [x] Write parameterized `acceptedEchoReusesOnlyTheRegisteredLocalRow` for acceptance-first/echo-first; include two equal-text prompts and local attachments/delegated/pasted metadata. Assert one correlated row, untouched unrelated row, retained UUID/local metadata, and canonical content.
- [x] Run the new projection suite RED with nonzero tests or compiler diagnostics identifying missing contracts.
- [x] Implement typed state, destination reservation and conversion. Use incremental transcript operations; preserve unknown content in typed state. Use existing pure formatters only where semantics match. Map tool fields and plans without inferring execution times or success. Store terminal output bytes and unknown exit status in typed state, never ACPTerminalHost.
- [x] Write `observerReplacementCannotMutateTheSuccessor` using the actual synchronous transcript ChangeSignal/onMessageAdded boundary. Stop/replace during row insertion/reconciliation and assert no subsequent old mutation or notification affects the new epoch. Also test invalid context/revision gap and row identity conflict block the projection.
- [x] Implement the smallest guarded transcript transaction seam that makes this pass. Validate/prepare before notification; handle observers before the underlying setter as well as after. Existing v1 transcript mutation APIs must retain their behavior. Do not use an isCurrent check only after an irreversible setter has already changed a successor.
- [x] Run bridge tests GREEN plus affected existing transcript/session suites selected by actual names in the repository. Record counts; no interim commit.

## Task 3: Runtime/bootstrap composition and lifecycle facts

**Interfaces**

Add optional `onCanonicalChange: (@MainActor (ACPV2SessionUpdateOwner.CanonicalPublication) throws -> Void)? = nil` to runtime and bootstrap initializers. Bootstrap forwards it before fresh setup default and runtime start. Runtime passes it to the sole update owner and rechecks its current epoch after invocation. A thrown callback leads to `.blocked(.updates(.projection(...)))` via the existing child-failure path and stops sibling authority synchronously. The projection's public `apply` method can be passed directly as the callback by an explicit integration caller.

The projection uses the publication's context and its own reservation epoch. It does not need to reconstruct the runtime's private request-handle epoch or expose it publicly. The two epochs are bound by the installed callback and shared current/stop lifecycle.

- [x] Extend runtime tests with `canonicalProjectionCannotSkipBurstCompletions`: feed several live intervals and assert every live completion notification in order while status readers lag. Assert acceptance has no completion or queue effect.
- [x] Extend bootstrap tests with `setupAndReplayPopulateProjectionWithoutLiveCompletion`: install bridge before createSession, assert setup default arrives before ingress, real reported running survives default, and snapshot restoration emits no live completion. Use the existing update replay fixture rather than introducing resume support.
- [x] Add parameterized runtime regression `projectionWithdrawalStopsSiblingEffects` for callback stop, throw, ownership loss and replacement. Block a real journal/command boundary with existing fixture gates; assert interrupted ACK and pending command handoff cannot happen and no late success is returned.
- [x] Run runtime/bootstrap focused tests RED, then implement forwarding, terminal propagation and post-callback fences. Keep existing request callbacks separate; never add another stream iterator.
- [x] Complete bridge tests `typedProjectionPreservesUnsupportedContentAndTerminalBytes` and `observationLossDoesNotInventIdleOrCompletion`: assert mixed known/unknown blocks, opaque numeric metadata, terminal snapshot/chunks including non-UTF8 bytes, requires_action without a fabricated dialog, and unknown stop reason. Snapshot/setup default never emits live completion; live completion notifications deduplicate by epoch/generation.
- [x] Run Task 1–3 suites GREEN. Inspect production call sites and prove no manager, runner or protocol selection installs this optional callback or bridge.

## Task 4: Final verification and review

- [x] Run the combined focused selection with actual nonzero counts: `ACPV2SessionProjectionTests|ACPV2SessionUpdateOwnerTests|ACPV2AttachmentRuntimeTests|ACPV2SessionBootstrapTests|ACPV2SessionStateTests|ACPV2MessageTranscriptTests|ACPV2ActivityStateTests|ACPBrokerRawClientTests|ACPV2InboundReceiptOwnerTests|ACPV2ResponseOwnerTests`, plus existing transcript suites affected by Task 2. Use the isolated package runner and retain the log path.
- [x] Run SwiftFormat lint for changed Swift files and `git diff --check`; check new files too. No native app build or repository-wide test plan unless implementation scope changes.
- [x] Update this plan's checkboxes and execution ledger with RED/GREEN evidence and material builder decisions. Report display limitations explicitly: typed unsupported records/terminals have no new renderer, no legacy row persistence or production installation.
- [x] Request one fresh final review of the actual diff against the approved design, scoped to ordered publications, identity reconciliation, observer reentrancy and authority withdrawal. Reproduce any Critical/Important findings before fixing; make one combined material fix pass and rerun relevant checks. Record declined findings and deferred Minors. No rereview.
- [x] Deliver changed behavior, exact test counts and limits. Leave related work uncommitted until the user asks to ship. Preserve unrelated changes throughout.

## Self-review

All design requirements map to Tasks 1–3: publication/provenance, exclusive installation, incremental rows/correlation, typed unsupported activity, completion semantics and failure/restoration. Task 4 supplies local evidence and one final review. The five review-focus cases each have named regression coverage above. No wire format, renderer, production installation or queue callback is introduced. Signatures and callback forwarding are consistent across tasks; revision belongs to canonical publications rather than latest-only status.

## Execution evidence and rulings

- Missing callback contract RED, then 26 owner tests GREEN. Initial bridge/owner selection passed31 tests/2 suites. Composition passed68 tests/5 suites.
- Pre-review combined selection passed173 tests/12 suites. An earlier combined run hit one existing burst timeout; the unchanged test passed alone in0.037s and the unchanged combined selection then passed. No timeout or code change was made for that failure.
- One fresh final review found0 Critical,4 Important,1 Minor. All4 material findings reproduced together in4 tests/2 suites with10 issues, then fixed in one combined pass. Focused validation passed72 tests/5 suites. The unregistered-row handoff check was additionally verified RED by removing that check alone, then restored. No rereview.
- Builder decisions: optional guarded storage in AlasFoundation preserves ordinary @Tracked behavior; minimal legacy runner reservation enforces destination exclusivity; typed v2 state retains canonical data without adding a renderer; intentional stop preserves last-known owner evidence but withdraws current projected activity; terminal notifications may run after runtime authority is gone and cannot authorize I/O; later prompts use explicit registerOptimisticRow before submit.
- Deferred Minor: bootstrap forwarding currently covers fresh setup, not actual replay. Projection-layer snapshot tests do not establish the complete replay/local-uncertainty provenance matrix. Attachment retention is pinned; the full delegated/pasted/symbol metadata matrix remains unverified. Claims are narrowed accordingly.
- Production/manager installation, live/published adapters, SSH/ownership transfer, resume/adoption, queues/request policies/completion hooks, process closure, new rendering, legacy row persistence, native app/CI/deployment and performance qualification remain outside this slice or unverified.

Final local verification: `/private/tmp/alas-projection-final-verified.log` passed177 tests in12 affected suites. `/private/tmp/alas-projection-final-lint.log` reports0/2780 files requiring formatting,1 skipped. Whitespace checks passed. No native app build, CI, live adapter or SSH pass is claimed. Feature work was left uncommitted until the subsequent explicit shipping request. Unrelated Ghostty/research changes remain excluded.
