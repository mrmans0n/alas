# ACP v2 raw broker payload contract

Status: approved with `Yes` on 2026-10-27. Builder check completed; its wrapper-duplicate ambiguity was resolved with a fixed two-element array.

## Intent and sequence

Continue umbrella #2213 after merged PR #2238, at fixed baseline `4a3ac981960c4c90ce66898741d4a6aa5026ef36` on `nacho/acp-v2-broker-payloads`. Preserve the existing untracked adapter-support research note. Keep this work local until a separate shipping request.

The merged direct-stdio path can deliver exact adapter frames, but the broker path still uses Swift `ACPBrokerJSONValue.number(Double)` and Rust `serde_json::Value` before those codecs run. A decoder installed only in ACPBrokerClient cannot recover values already changed or rejected upstream.

Split that work into reviewable steps. This slice establishes a shared byte-preserving payload contract across Swift and Rust, with cross-language fixtures and transit tests. The following slice installs helper capture, journals/caches, feature negotiation and broker delivery against that contract. This slice must not be described as end-to-end broker or SSH v2 support.

## Scope and non-goals

Add one explicit payload value to the Swift platform broker protocol layer and its Rust counterpart. It carries source JSON bytes as opaque bytes through generic JSON-based helper/broker envelopes. The wrapper itself does not parse, validate, normalize or repair the source JSON.

Production selection remains v1, the Debug preference remains default-off, and live v2 eligibility stays empty. Do not change existing broker methods, event cases, snapshots, send results, pending client requests, outgoing ACP requests, initialization or cached-result handling in this slice. Do not advertise a new helper capability before capture/delivery exists. Do not replace the legacy JSON value representation globally or enable arbitrary-precision parsing globally.

No runtime adapter launch, raw-frame capture, journal/IPC installation, broker-client v2 stream, SSH deployment, helper binary/version publication, runner, persistence/replay, cursor/lease/ACK, queue, permissions, or UI changes. Existing v1 behavior is unchanged.

## Wire contract

Recommended public Swift type: `ACPBrokerRawJSONPayload`, in AlasPlatform's SSH protocol directory. Recommended Rust counterpart: `AcpRawJSONPayload`, in `acp_broker_protocol.rs`. Both expose immutable decoded bytes and construction from bytes. Exact naming and accessor spelling are builder choices.

Use this exact wrapper shape at an explicitly typed protocol boundary:

```json
["alas.acp.raw-json.v1","<canonical padded RFC 4648 base64>"]
```

The array has exactly two elements, both required strings: format first, canonical base64 second. Reject other container types, missing/extra elements, null/wrong-shaped elements, unsupported format strings, invalid base64, ignored characters, unpadded forms, and noncanonical pad bits. Compare decoded bytes re-encoded with the standard alphabet to the original data string. New formats require a new discriminator; do not accept trailing values as an implicit upgrade. An unsupported format is a decoding error, never an instruction to try a legacy numeric representation.

The fixed pair avoids duplicate object-member interpretation differing between Swift's and Rust's generic decoders. Duplicate keys inside the source JSON remain opaque preserved bytes. This shape choice is mine, made after the builder check identified the ambiguity.

The discriminator belongs only to a field explicitly typed as this payload. Never scan arbitrary adapter JSON arrays for markers or reinterpret a coincidentally matching user array. This prevents marker collisions.

Use standard generic JSON encoders/decoders for the pair's strings. Source bytes must never be inserted as nested JSON or passed through Double, AnyCodable, JSONSerialization, or serde_json::Value before wrapping. Passing the wrapper itself through generic Value/object carriers is safe because the payload remains a string.

Preserve the original bytes, including whitespace, numeric token spelling, key order, duplicate keys, invalid JSON, and invalid UTF-8. A received payload is evidence, not a successfully decoded ACP event. Consumers must later use the exact ACP codecs and handle their errors explicitly. Do not add acknowledgement callbacks or connection/session authority to this passive transport value.

Base64 adds about one third to the source byte count. Existing transport size/replay budgets still apply to serialized wire bytes when this contract is installed later; this slice does not raise limits, add chunking, silently truncate or introduce a second payload budget.

## Compatibility and future installation boundary

The new type is additive and unused by production broker schemas in this PR. Old helpers and cached generations cannot gain raw support from its existence. Missing raw support remains unverified, not upgraded by re-encoding old structured values.

The next installation design must negotiate an explicit raw-payload capability before use, bind that encoding and ACP version to the broker generation, reject mismatched adoption/attachment, and preserve captured bytes through notifications, operation outcomes, initialization/session caches and pending requests. It must capture adapter bytes before numeric decoding, preserve the old v1 route, and retain cursor ordering, hook-review-rejection retention, operation deduplication, leases and durable consumption. Broker turn-state completion still needs its own v2 lifecycle integration; raw bytes alone do not fix prompt-response completion semantics.

Keep these as explicit follow-up requirements, not incomplete promises hidden in this PR's acceptance criteria.

## Files and tests

- Swift production: add the wrapper under `Packages/AlasCore/Sources/AlasPlatform/SSH/`. Keep it independent of AlasCode, which already depends on AlasPlatform.
- Swift tests: one coherent new `ACPBrokerRawJSONPayloadTests` package suite. Do not add app-build-only coverage for this pure codec.
- Rust production/tests: extend `AlasHelper/src/acp_broker_protocol.rs` and the existing `AlasHelper/tests/acp_broker_protocol.rs` suite. Reuse the existing base64 dependency.
- Share a small committed fixture corpus under a repository fixture directory, read by both test suites. Exact fixture location and loader mechanics are builder choices; avoid absolute paths and generated golden files that merely duplicate each implementation.

Meaningful acceptance cases:

1. Swift and Rust decode the same fixtures and independently assert exact source bytes containing `1e999`, a large integer, `1.00e2`, nested unknown values and non-ASCII text. Neither generic numeric decoder may see those source tokens.
2. Each side encodes a payload that passes through a generic object/value carrier and a second encode/decode hop, then asserts byte equality against a literal fixture expectation. Include a broker-like event and cached-outcome carrier, without changing production schemas or asserting real journal behavior.
3. Malformed JSON, duplicate keys and invalid UTF-8 survive as bytes without being accepted as semantic ACP data. The wrapper must not normalize or silently reject diagnostic evidence.
4. Parameterized malformed-wrapper cases reject unsupported/missing/null/wrong-type elements, extra elements, object containers and noncanonical base64. Use a source payload containing the same marker array to prove no recursive marker interpretation.

Write failing contract tests before production implementation. Run affected AlasCore package suites first, then focused Rust broker protocol tests and formatting/whitespace checks. Inspect actual selected test counts. This slice needs no app build, real SSH host or adapter package. Do not claim runtime interoperability from codec fixtures.

Obtain one fresh final code review and fix material findings with regression evidence. Update umbrella #2213 with the contract-only result, leaving helper capture, broker/SSH integration and live eligibility unchecked.

## Choices left to the builder

The byte-preserving wrapper, wire discriminator, canonical base64, additive unused contract, error/compatibility behavior and acceptance cases above are design recommendations. Type naming, helper placement, fixture layout and bounded test organization are builder choices. The split into a contract PR before installation is my recommendation to keep the transport change reviewable; it is not a previous user requirement.
