# ACP v2 tools, plans, and display terminals

Status: approved with `sgtm` on 2026-10-26. Design review found no important unanswered questions.

## Intent and boundary

Continue [umbrella #2213](https://github.com/mrmans0n/alas/issues/2213) after [PR #2222](https://github.com/mrmans0n/alas/pull/2222). Model the remaining core transcript entities so a later integration can project a complete v2 conversation without translating it through v1 assumptions.

The next slice extends v2 decoding and adds a UI-free state reducer for tool calls, plans, and agent-owned display terminals. It returns state-change effects and the original lossless event. No transport handler, UI projection, persistence migration, permission handler, terminal execution, adapter adoption, or live v2 eligibility is installed. Notices and compaction remain raw unhandled events. Full transcript/restoration workstream 3 remains partial.

These entities belong in one slice because tool content can reference a display terminal before or after its state arrives. All five update variants use the same connection/session context and raw envelope. Their state stays separate from foreground completion and local prompt acceptance.

## Wire decoding

Extend `ACPV2SessionUpdateEnvelope` with typed payloads for `tool_call_update`, `tool_call_content_chunk`, `plan_update`, `terminal_update`, and `terminal_output_chunk`. Keep the existing message API and semantics compatible; a typed payload enum with a compatible message accessor is the recommended shape. Group the new payload decoding separately from message-only parsing rather than growing one large decoder.

Retain `rawValue` and the explicit `decode(from:)` / `encodedData()` wire entry points. Unknown fields, opaque content, unknown string variants, and arbitrary numeric tokens must survive round trips. Unknown non-message update kinds still produce no semantic mutation. A required ID, discriminator, or required container with the wrong shape is a decoding error, not an unknown variant.

Use explicit omitted/null/value patches for interpreted optional fields. Validate their supplied types before reduction; malformed interpreted fields fail without partly applying the event. Never turn a malformed value into a clear or a familiar enum value. This follows the strict known-shape policy of the message foundation. Generator-specific schema hints do not justify silently clearing stored values.

Validate the structural fields needed by this reducer. Tool content items remain raw objects with string `type` discriminators. Interpret `type: "terminal"` enough to require and retain its string `terminalId`; unknown content types retain their complete object. Other content and diff bodies stay opaque for later rendering validation. Do not parse patch text into file operations or claim complete nested-content schema validation.

Known metadata containers must be objects or null. Tool/terminal top-level `_meta` patches entity metadata by top-level key. Chunk, notification, content-item, terminal-output snapshot, exit-information, plan-value, and plan-entry metadata describe only their carrying object and do not patch unrelated entity metadata. Preserve those raw objects with the decoded event.

Known uint32 fields are checked by numeric value and bounds, not decimal-token spelling; an integral JSON value such as `1e2` is still an integer. Preserve its original token in the raw envelope. Fractions, negative values, and values above `4294967295` are invalid for those fields.

## Canonical state and effects

Add public values and a deterministic reducer in the existing `AlasACP` target. Reuse the message foundation's immutable session/connection context, extracting a shared value with a compatible type alias if needed. Caller-supplied context and envelope session ID must both match before any mutation, including creation of referenced terminals.

Maintain separate identities for tool calls, plans, and display terminals. Equal ID strings across those types, or across a message and a tool, never identify the same entity. Preserve first-observed order within the activity state; later updates do not move an entity. Return ordered effects for changed entities and the original envelope even when no change occurs.

This reducer does not establish global UI row order across the separate message and activity models. The later projection owner must consume their full receive stream in order. Do not infer cross-model ordering from IDs, wall time, or separate array indices.

No clocks, processes, filesystem access, UI callbacks, queue operations, or acknowledgments belong inside the reducer. Unknown/unhandled events, stale contexts, and decoding failures cannot imply completion, success, permissions, or upstream durability.

## Tool calls

`tool_call_update` is an upsert. The first update or content chunk for a `toolCallId` creates its state; no v1 `tool_call` announcement is required.

Model `name`, `title`, `kind`, `status`, `content`, `locations`, `rawInput`, `rawOutput`, and entity metadata without flattening structured JSON. For a first-seen call, omitted `kind` starts as `other` and omitted `status` as `pending`; title/name/raw values start absent, and content/locations/metadata empty. Explicit null clears the field, including an initially supplied null status becoming unknown rather than success. Later omission always preserves the current value.

Concrete scalar fields replace their values. Preserve unfamiliar kind/status strings; they never become `completed` through a fallback. Name is informational and grants no capability. `rawInput` and `rawOutput` preserve arbitrary non-null JSON; null clears them rather than storing a literal null.

Whole `content` and `locations` arrays replace prior arrays; null or an empty array clears them. Preserve structured locations; require a string path on a location and a nullable, nonnegative uint32 line when present. Keep agent paths as protocol data without resolving them against the client's filesystem.

`tool_call_content_chunk` requires a single content item and appends it in receive order. A later replacement discards all previous content, including chunks. Identical chunks both append, with no text matching, inserted separator, or replay suppression. A repeated identical replacement has no additional state-change effect.

Metadata follows the existing message patch contract: omit preserves, null clears all keys, and an object patches one top-level key at a time. A null key removes it, another value replaces it whole, and nested objects are not deep-merged. Content replacement does not reset unspecified metadata.

## Plans

`plan_update` requires a `plan` object with string `type` and `planId`. For `type: "items"`, require the complete `entries` array; each entry requires string `content`, `priority`, and `status`. Preserve unknown priority/status strings and all additional entry fields.

Each update replaces the full value of that one plan. Empty entries clear its items. Do not merge by array position or collapse multiple plan IDs into the v1 current-plan slot. Plan-value and entry metadata belong to the replacement value; omission/null means no metadata on that new object, not a patch preserving prior metadata. Update-level and notification-level metadata remain event-scoped.

For an unknown string plan type, still require `planId`, retain the entire plan as opaque content at that identity, and replace its previously materialized view with an explicit opaque value. Do not interpret it as an item list, retain an old list as if current, or implement unstable plan operations. A later concrete items update can replace that opaque value normally.

## Agent-owned display terminals

Use a distinct display-terminal value, never `ACPTerminalHost.create` or the v1 process-backed execution API. Command, cwd, status, and output are reported data; receiving them cannot run or kill a command, change directory, or authorize a tool. Keep cwd as the supplied protocol path without normalizing it against the Mac's cwd. Absolute-path correctness belongs to the reporting agent; this reducer validates its string shape rather than applying client-platform path rules.

Create an empty/unknown terminal record on its first recognized tool-content reference, `terminal_update`, or `terminal_output_chunk`. References and state/output may arrive in either order. A later reference resolves the already-known state; a later state update fills its placeholder. Removing or replacing a tool's content does not delete terminal state, which may have other references or later updates. Unknown content variants with a field named `terminalId` do not create references.

`terminal_update` patches `command`, `cwd`, `output`, `exitStatus`, and entity metadata. Omission preserves each field; null clears it; a concrete value replaces it. New records start with no command/cwd/exit information and empty output bytes.

- A concrete `output` object requires a base64 `data` string. Decode it to an authoritative byte snapshot that replaces all previous bytes. Do not merge prefixes or splice old bytes into it. Null output clears bytes and snapshot metadata.
- `terminal_output_chunk` requires its own base64 `data` string. Decode each chunk separately and append the decoded bytes in received order. Never concatenate encoded strings or deduplicate equal chunks. Invalid base64 is a decoding error with no state change; do not use an ignore-invalid-characters option.
- Store bytes, not per-chunk UTF-8 strings. A code point or terminal escape sequence split across chunks must remain exact. Rendering and parser-state integration are later work.
- Snapshot metadata is stored with that snapshot, not merged into terminal metadata. Replacing a snapshot replaces its metadata; omitted/null snapshot metadata means none. Appending chunks leaves that snapshot metadata as provenance of the last snapshot, not metadata for the appended chunks. Chunk metadata stays in the raw event.
- A concrete `exitStatus`, including `{}`, means exit was reported, even with no known code/signal. Optional code must be a nonnegative uint32; optional signal is a string; omission/null means unspecified. The whole exit-information object replaces the prior one. Null exitStatus clears the report and means unknown, not proof of running.
- Exit-information metadata is scoped to that exit object. Terminal entity metadata uses the top-level patch rule. A tool's terminal reference does not patch terminal metadata.

Terminal exit and tool-call status remain independent. A zero exit code cannot finish its tool call, and a completed tool cannot fabricate an exited terminal. Neither ends foreground work. Tool updates, references, and terminal changes from one envelope must validate before any state is mutated; callers never observe half an applied event.

## Compatibility and scope constraints

Do not change the v1 update decoder, `ACPSession.apply`, legacy tool-content flattening, terminal execution host, plan UI, transcript codecs, hydration, `restoreQueue`, broker generations, acknowledgments, lease checks, or protocol eligibility. The existing message reducer and prompt-correlation behavior must keep passing their tests.

Promoting previously unhandled activity variants to known decoding means existing unknown-variant fixtures must use a genuinely unknown kind or valid activity payload. Do not weaken known decoding to preserve an intentionally malformed old fixture. Keep notice, compaction, foreground state, permission, and other unrelated semantics outside this activity reducer.

Raw event preservation is an in-memory/round-trip guarantee here. It is not a claim that the app stores or replays the event durably. No full replay, cross-version resume, rendering, filesystem edits, or live adapter interoperability is demonstrated by this slice. The Debug flag remains default-off and live v2 eligibility empty.

## Validation and acceptance criteria

Use Swift Testing in AlasCore. Extend the existing decoder suite for new envelope cases and add one coherent suite for the new activity reducer, not scenario-sliced sibling files. Values and ordered events require no sleeps, process fakes, sockets, or app windows.

- Exercise the five variants, opaque content/unknown fields/numbers, malformed required/interpreted shapes, and encode/decode preservation.
- Cover tool creation from an update or chunk, omission versus null, scalar/raw replacements, equal chunks, replacement after chunks, array clearing, and metadata key removal/nested replacement without content-reset side effects.
- Keep equal IDs across message/tool/plan/terminal identities distinct; stale session or connection context produces no entity or reference mutation.
- Replace a plan's full list, preserve independent plans, retain future priority/status values, and transition between items and opaque plan types without showing a stale item list.
- Cover terminal reference before/after state, output before a reference, and removing a reference without deleting state. Equal ID strings must not couple terminal exit to tool status.
- Verify independent padded base64 chunks, repeated chunks, output snapshot replacement after chunks, null output, invalid base64, split UTF-8/escape bytes, and scoped snapshot/chunk/entity metadata.
- Distinguish absent exit information from a concrete empty exit report, a nonzero code, and a signal-only exit; explicit null clears the report without asserting running.
- Run affected package suites including message, activity, lifecycle, and negotiation tests. Run SwiftFormat lint with the repository config and `git diff --check`; the previous PR's semicolon failure must be caught locally. No full local test plan or app build is needed if implementation stays within this package-only boundary.

Keep implementation local until a shipping request and preserve the pre-existing research note. Update the umbrella with locally complete versus deferred work after verification, without checking off full live transcript/restoration support.

## Evidence and choices left to the builder

The new branch `nacho/acp-v2-activity-entities` starts at merged main `62be9d31de41635b29da6962eca9b3f07c952c67`. The v1 tool update cannot represent all v2 null-clears, the v1 plan has no plan ID, and `ACPTerminalHost` owns process execution as well as metadata displays. Those are reasons to keep this v2 canonical state separate until projection is designed.

The core-only boundary, explicit initial tool defaults, opaque-plan replacement, and raw-byte terminal state are implementation recommendations. Exact type/file names, typed versus raw storage of uninterpreted fields, and small shared patch/context helpers are left to the builder. Keep public APIs small; do not add a general event framework or a process/renderer dependency.

Sources are pinned to the umbrella's protocol revision. The current upstream tool-call and plan documents were also fetched on 2026-10-26 and are byte-identical to these pinned versions:

- [Tool upserts, content streaming, and display terminals](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/tool-calls.mdx)
- [Identified plans and full replacement](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/agent-plan.mdx)
- [Stable v2 schema](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/schema/v2/schema.json)
- [Metadata scopes and patches](https://github.com/agentclientprotocol/agent-client-protocol/blob/41c6a98caa3dea7d8e05a8013348e266dd4286e1/docs/protocol/v2/extensibility.mdx)
