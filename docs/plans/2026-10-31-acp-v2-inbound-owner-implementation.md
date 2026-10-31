# ACP 2 inbound receipt owner implementation plan

> **For agentic workers:** Use superpowers:executing-plans with approved inline TDD and one fresh final review. No commits until shipping requested.

**Goal:** Restore a retained prefix and sequentially commit/consume exact inbound receipts under current attachment ownership.

**Architecture:** One main-actor owner and receive task in AlasSessions. The existing persistence actor conforms to a narrow protocol; existing stdio/common and broker/facade streams feed the same loop without another queue. Observations are latest-only durable facts, never pending/request/response authority.

**Tech stack:** Swift, Swift Testing, existing schema33 SQLite ledger.

**Spec:** [Approved design](2026-10-31-acp-v2-inbound-owner-design.md).

## Constraints and files

- Branch nacho/acp-v2-inbound-owner, base26fe6397de2edd0c4ab6d325e33aa15fbbf48665. Preserve unrelated Ghostty/research. Production remains v1-only.
- No response intent/reply/execution, helper/Rust/schema changes, current pending map, canonical state/queue/UI/runner/SSH integration.
- Create AlasSessions/ACP/Session/ACPV2InboundReceiptOwner.swift: protocol, actor conformance, immutable attachment, owner and typed observations/failures. Split protocol adjacent only if clarity warrants it.
- Create package ACPV2InboundReceiptOwnerTests.swift for the new owner; extend existing ACPBrokerRawClientTests.swift for concrete broker integration. No app files expected, so no native build unless scope changes.
- Use exact UTF-8 metadata identity, original immutable receipt source, fixed baseline,128-record/1MiB replay defaults and one current page/latest record. Replay never creates a live delivery.

## Interfaces

ACPV2InboundLedgerPersisting: Sendable consumes existing registerV2InboundLedger, retainV2Inbound, loadV2InboundLedgerPage signatures as async throwing methods. ACPSessionPersistence conforms.

Main-actor ACPV2InboundReceiptOwner:
- Attachment.init(stdioClient:) throws; init(brokerClient:opened:) throws, validating selected-v2 identities/open context and local metadata. Reuse existing read-only v2PromptEndpoint for broker identity, no sending.
- init(sessionId:upstreamSessionId:attachment:fence:journal:isCurrent:), start(AsyncStream<ACPV2InboundDelivery>), start(AsyncStream<ACPBrokerRawFrameDelivery>) -> Bool, stop(), waitUntilFinished() async.
- Read-only stream, lastRetainedOrdinal, hasKnownMissingPrefix, status, latestReceipt and observations. Status idle/restoring/receiving/observationLost/stopped/blocked. Receipt observation contains record and origin historical/inserted/duplicate, no callback or durable-write receipt.
- Failures distinguish invalidAttachment, ownershipLost, deliveryMismatch, invalidProof, ordinalGap, typed journal(operation,error) and persistence(operation,message). Operation registration/replay/retention.

## Review focus

- A broker retry uses a different capture UUID/connection/origin but the same exact event/bytes/pending ID; only the current handle can be consumed. Task1/2.
- Stop/observed replacement after COMMIT must suppress publication/ACK while leaving recoverable storage; synchronous predicate/callback reentry cannot revive stopped state. Task2.
- Historical replay may contain malformed bytes and other capture connections; source/ordinal metadata still requires strict validation. Task1/2.
- An inconsistent receipt or missing replay ordinal cannot be treated as committed current proof. No payload parsing or liveness inference can substitute for byte/source checks. Task2.
- A concrete broker stream must use its stored common view with no mapping task/stream, responses, queue effects or stolen update ownership. Task3.

## Task1: Ordered restore/retain owner

- [x] Write failing basic owner tests with real ledger: equal/malformed/binary captures, copied retries,130-record restoration, old-source exclusion and no callback reconstruction. Observe missing-contract RED.
- [x] Implement attachment/protocol/owner, bounded replay and sequential retain-before-consume. Validate descriptor/record/proof/source/ordinals, exact UTF-8 pending IDs. Two start overloads feed one task via direct sequence transformation. Publish latest-only observations; EOF observation loss, synchronous stop, current predicate checked after awaits and again after predicate reentry.
- [x] Run new owner plus existing inbound/update owner/negotiation/restore suites, inspect actual counts and record GREEN. No commit.

## Task2: Failure and lifetime boundaries

- [x] Add event-gated registration/replay/retention entry/return cases for stop/observed ownership loss, committed unpublished recovery, real stale fence and SQL failure, wrong connection/source and inconsistent returned proof/page. Include ordinal gaps, unsupported stored format, v1 rejection, predicate reentry and callbacks that synchronously stop. Observe regressions where guards are absent; characterize guards already required by Task1 without removing correct behavior.
- [x] Fix only demonstrated failures. All failures preserve the known prefix and stop further input; no callback on rejected/unpublished evidence and stopped is never overwritten. Run affected suites and record counts. No commit.

## Task3: Concrete broker and final verification

- [x] Extend existing broker suite for direct facade-stream owner integration, restored pending snapshot retry/ACK origin and no respond/close calls. Reject v1/mismatched broker open identities. Run affected broker/helper/common/owner suites.
- [x] Full SwiftFormat lint and tracked/new-file whitespace checks. No app/native build for this package-only slice; do not repair unrelated cache/submodule state.
- [x] One fresh whole-change review against fixed base including untracked files and excluding unrelated inputs. One material RED/GREEN fix pass if needed, no rereview. Complete plan/ledger and umbrella2213 with evidence, choices and remaining origin-fenced reply/current-reconciliation scope. Keep uncommitted until shipping requested.

## Preflight rulings

Retain the approved inline method without another execution menu. Repository focused checks and no-commit-until-shipping override generic skill defaults. No shared-interface conflict: Task1 uses merged immutable ledger values; Task2 gates that protocol; Task3 consumes existing broker facade. Response transport remains unsafe by reusable wire ID and is deliberately not called.

## Completion evidence

- Missing owner/protocol contract RED followed by43 tests/5 suites GREEN.
- Failure/lifetime characterization passed8 owner definitions/1 suite, including12 entry/return stop/replacement variants, committed unpublished recovery, stale lease, real SQL rollback, inconsistent proof/page and synchronous predicate/consumption reentry. Guards already required by Task1 were characterized without manufacturing failures.
- Broker integration selection passed77 tests/8 suites. Direct facade-stream retention/ACK, already-ACKed pending redelivery, exact proof metadata and invalid attachment/v1 rejection passed. A test-only compound async expectation needed splitting for actor isolation; no product change.
- Final affected package selection passed160 tests/14 suites. Full SwiftFormat lint reports0/2717 files requiring formatting,1 skipped; tracked/new-file whitespace checks passed.
- One fresh whole-change review found no Critical, Important or Minor findings. No fix pass, rereview or deferred minors.
- Accepted review exclusions: replies/liveness/execution/canonical/queue/UI/runner/production integration, real helper/adapter interoperability and remote ACK completion, and unrelated Ghostty/research inputs. No app files changed, so no native build was needed; no native/CI/live adapter/SSH result is claimed.

Choices retained: use the existing read-only endpoint identity without invoking submission; preserve the approved inline/focused workflow; expose latest-only receipt facts rather than a pending-request map. These introduce no reply authority or atomic SQLite-to-remote guarantee. A future reply owner still needs origin-fenced handoff and current-attachment reconciliation.

Umbrella2213 records local implementation and the remaining reply-contract/intent/response-owner work. Shipping was authorized after implementation; the pre-PR verification again passed160 tests/14 suites and full SwiftFormat lint.
