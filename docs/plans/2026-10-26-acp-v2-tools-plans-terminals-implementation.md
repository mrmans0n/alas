# ACP v2 tools, plans, and display terminals implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Decode and reduce identified v2 tool calls, plans, and byte-based display terminals without activating live v2.

**Architecture:** Extend the lossless v2 envelope with typed payloads and preserve its message accessor. A separate activity reducer shares the existing immutable connection/session context. Small value-patch and metadata helpers implement consistent null/omit semantics; no app, process, UI, or storage owner is installed.

**Tech stack:** Swift, Swift Testing, existing AlasACP package target.

**Spec:** [Approved design](2026-10-26-acp-v2-tools-plans-terminals-design.md).

## Global constraints

- Production stays v1; no transport, UI, storage, replay, permission, terminal execution, or adapter changes.
- Preserve raw envelopes, unknown fields, scoped metadata, and exact opaque numeric tokens.
- Required/interpreted malformed values fail before any state mutation. Numeric uint32 values follow mathematical value and bounds.
- Equal chunks append; snapshots and lists replace; terminal exit, tool status, and foreground completion stay independent.
- Reuse the isolated SwiftPM scratch/cache paths and focused package selection. Run SwiftFormat with the repository config before finishing.
- Keep changes local until shipping and preserve the existing untracked research note.

## Review focus

- A terminal reference can precede any terminal update, share a string ID with its tool, and later be removed without deleting terminal state.
- Optional null clears differ from omission; raw-input null is a clear, while nested metadata null remains data.
- Empty exit information reports an exit, not running or success; signal-only and nonzero exits remain independent of tool status.
- Base64 chunks decode independently; snapshots replace bytes and scoped snapshot metadata, including after partial UTF-8 or escape sequences.
- Unknown plan types replace old materialized items with opaque values; stale contexts never create reference placeholders.

## Task 1: Typed activity wire payloads

Files: modify `Packages/AlasCore/Sources/AlasACP/ACP/Protocol/ACPV2SessionUpdateEnvelope.swift`; create `ACPV2ActivityUpdate.swift` in that directory; extend `Packages/AlasCore/Tests/AlasCoreTests/ACPV2MessageTranscriptTests.swift`.

Interfaces: `Envelope.Payload` exposes message, tool-call patch, tool-content chunk, plan value, terminal patch, terminal-byte chunk, and unhandled cases. Keep `message` as a compatible computed accessor. `ValuePatch<Value>` represents omitted/clear/value. Typed tool content carries the original raw item and an optional validated terminal reference. Plans retain their full raw value. Output snapshots carry decoded Data and snapshot metadata; exit information carries optional uint32 code/signal and its original object.

- [x] Add lossless five-variant fixtures, malformed interpreted payloads, and mathematical uint32 cases in the existing decoder suite. Replace formerly unknown activity fixtures with genuinely unhandled variants. Observe the absent typed-payload contract.
- [x] Implement typed payload parsing, raw content/reference validation, scoped metadata validation, exact uint32 conversion, and strict independent base64 decoding. Keep malformed values out of state.
- [x] Run the message suite and inspect actual counts. Resolve the shared metadata application helper without changing existing message semantics.

## Task 2: Canonical tool and plan state

Files: create `Packages/AlasCore/Sources/AlasACP/ACP/Session/ACPV2ActivityState.swift`; create `Packages/AlasCore/Tests/AlasCoreTests/ACPV2ActivityStateTests.swift`; make only a metadata-helper substitution in the existing message reducer if useful.

Interfaces: `ACPV2ActivityState(context:)` reuses `ACPV2MessageTranscript.Context`; lookup functions expose tool/plan state, and ordered type-plus-ID keys retain first observation. `apply(_:context:) -> Reduction` retains the raw event, applied/unhandled/stale disposition, and typed changed-entity effects. Tool values preserve scalar/raw/structured fields; plan values replace one identified plan wholly.

- [x] Add traces for creation by update/chunk, clear versus omission, raw replacements, metadata scope, equal chunks, independent IDs, full plan replacement/opaque transitions, and stale contexts. Observe the missing reducer contract.
- [x] Implement tool and plan reduction with pending/other initial tool defaults, atomic context guards, and no completion or execution effects.
- [x] Run activity/message/lifecycle/negotiation suites and inspect counts.

## Task 3: Display-terminal bytes and references

Files: extend the activity reducer and its existing suite.

Interfaces: display-terminal values expose command/cwd data, output Data, last-snapshot metadata, optional exit-information object, and entity metadata. Tool references create unknown placeholders; terminal snapshots/chunks update that same record. Reduction effects include changed terminals without invoking any execution host.

- [x] Add reference/state ordering, retention after reference removal, independent statuses, byte/snapshot traces, scoped metadata, empty/signal/code exit reports, invalid payload atomicity, and stale-reference cases. Observe behavioral failure before implementing terminal reduction.
- [x] Implement first-reference placeholders, independently decoded byte appends, authoritative snapshot replacement, optional exit replacement/clear, and correct metadata scopes.
- [x] Run the focused four-suite selection, SwiftFormat lint, and whitespace checks. Inspect the full diff and obtain one fresh-context review. Fix actionable findings with regression evidence.
- [x] Update plan and umbrella with completed local work and deferred integration. Leave changes uncommitted until shipping.

## Result

Implemented on `nacho/acp-v2-activity-entities`, based on `62be9d31de41635b29da6962eca9b3f07c952c67`. Publication was authorized on 2026-10-26. The pre-existing research note is excluded.

- Typed activity decoding and canonical tool/plan/display-terminal state are complete within the approved package-only boundary. Live v2 eligibility remains empty.
- Independent review found no wire-decoded context, ordering, atomicity, metadata-scope, or terminal-status defect. Its raw-value-initializer finding reproduced malformed number tokens becoming interpreted exit codes; the fix reuses exact JSON grammar validation before uint32 conversion. The new regression failed first and passed after the fix. No second review was dispatched.
- The final focused run passed 51 tests in 4 suites: `ACPV2ActivityStateTests`, `ACPV2MessageTranscriptTests`, `ACPSessionLifecycleTests`, and `ACPProtocolNegotiationTests`.
- Full SwiftFormat lint reported `0/2640 files require formatting, 1 file skipped`. Whitespace checks passed for tracked and new scoped files.
- [Umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) tracks this foundation alongside the remaining integration. UI projection, durable storage/replay, live dispatch, adapters, and execution-host integration remain pending; no app build, CI, or live interoperability result is claimed by this local validation.

Evidence logs are local: `/private/tmp/alas-acp2-activity-review-red.log`, `/private/tmp/alas-acp2-activity-reviewed.log`, and `/private/tmp/alas-acp2-activity-format-reviewed.log`.

Deferred minor: add an extra snapshot-replacement trace immediately after incomplete UTF-8 or escape bytes. The existing byte trace completes split sequences before replacing the snapshot; the implementation retains Data and replaces it whole.
