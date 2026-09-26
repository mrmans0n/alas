# Session resume card design

Issue: [#1481](https://github.com/mrmans0n/alas/issues/1481)

## Goal

Let a user explicitly summarize an idle ACP session with the already installed on-device Qwen model. A toolbar control opens a plan-style popover containing a bounded account of the session goal, completed work, blockers, and next action. The summary helps the user resume work; it does not send a prompt, execute a tool, or change session state.

Session summaries are an independent experimental capability. They share the verified model installation and native MLX lifecycle introduced for next-prompt suggestions, but have their own setting, prompt, context builder, parser, policy, request state, cache, and UI.

## Non-goals

- Automatic summarization on launch, session selection, inactivity, or app termination.
- Persistent summaries, database migrations, transcript telemetry, or retained inference prompts.
- Summarizing raw tool input/output, file contents or edits, attachments, thoughts, hidden provider state, permissions, questions, or system notices.
- Sending the generated next action, editing the composer, deciding task success, or authorizing scheduled cleanup.
- Changing Apple Foundation Models title generation.
- A general-purpose local-model API for arbitrary callers. The shared layer covers only the model mechanics required by the two concrete features.

## User experience

Add a **Summarize Session** control to `ACPToolbar`. It is hidden when Session summaries is disabled or the platform is unsupported. Once enabled, it remains visible but disabled while the shared model is downloading, verifying, failed, or otherwise unavailable; its help and accessibility value explain the current state.

Selecting the control opens an anchored popover following `ACPPlanPill` and `ACPPlanChecklist` conventions. The trigger remains visually active while the popover is open. A first open starts generation and immediately shows progress. A validated result replaces progress without closing the popover.

The popover has a **Session summary** header and four accessible sections:

- **Goal**
- **Completed**
- **Blockers**
- **Next action**

Empty optional sections are omitted. When the context builder dropped older turns, the header states that the summary covers recent context. The popover offers **Refresh** after a result or failure.

A successful result remains cached in memory while Alas runs. Closing and reopening the popover reuses it without loading the model again. Relaunching Alas, deleting the session, or replacing its incarnation discards it.

Any new prompt, queue, streaming, permission, question, retry, recovery, delegated, or auto-run activity closes the popover, cancels unfinished summary generation, and invalidates the cached summary before work begins. When the session becomes idle, another explicit open generates a fresh result.

If Refresh fails without intervening session activity, the prior successful summary remains visible with a compact error and Retry action. A first-generation failure shows the error and Retry action without empty section placeholders.

## Settings and shared installation

Add `sessionSummariesEnabled` to `AppConfig`, defaulting to `false` when absent. Keep the capability under Settings → Debug → Experimental while local-model use remains experimental.

Refactor the existing next-prompt settings presentation into one on-device-model area with two independent capability rows:

- Next-prompt suggestions
- Session summaries

Enabling either capability while the model is absent presents capability-specific consent describing the roughly 2.3 GB download, local transcript processing, multi-gigabyte memory use, and retained process memory observed after unload. One accepted installation serves both capabilities. Disabling one capability cancels only its work and leaves the other enabled.

The shared model can be removed only when both capabilities are disabled. Existing cross-process lease checks still prevent removal while another Alas process uses it. A failed setting write keeps the affected capability off for the current process and exposes the same retryable persistence state used by next-prompt suggestions.

When both capabilities are disabled, startup does not inspect or hash an existing model installation. Opening the on-device-model settings area may inspect it on demand so removal and readiness status remain accurate. If either capability is enabled, startup performs the existing verified inspection before allowing inference.

Unsupported Release builds return before model inspection or observer setup. They do not hash or load an existing installation.

## Shared model architecture

The second production use justifies extracting the mechanics currently embedded in next-prompt types. Rename or move only the pieces that are truly model-wide:

- Manifest and pinned asset metadata.
- Installation, inspection, verification, cancellation, removal, and model state.
- Stable cross-process read leases.
- Native Qwen loading and the single in-process MLX container.
- Serialized generation, deadlines, caller cancellation, idle unload, and memory-pressure unload.

A `LocalTextInferenceEngine` actor accepts already rendered chat messages, bounded generation parameters, a caller identity, and a priority. It returns raw generated text or a typed operational failure. It does not know about ACP sessions, summaries, next-prompt offers, feature settings, parsing, or UI.

The engine owns one native container and at most one active generation. Automatic next-prompt work uses background priority. An explicit session-summary request uses user-initiated priority: it cancels and drains automatic suggestion work before starting. A newer user-initiated request replaces an older one. The existing verified lease remains held through native drain and unload.

`NextPromptInference` remains the owner of suggestion-specific repeated-failure suppression, input/output policy, deadlines, parsing, and state publication. It delegates raw native work to the shared engine. Summary failures never increment next-prompt suppression, and next-prompt failures never disable summaries.

Do not extract a generic prompt registry, feature protocol, UI abstraction, or persistence layer. A future third use can generalize further only from another concrete implementation.

## Summary components and state

Add feature-local components with narrow responsibilities:

- `SessionSummaryContext` builds an immutable bounded snapshot from an idle `ACPSession`.
- `SessionSummaryPolicy` renders model messages, parses the exact response shape, validates bounds, and applies output safety checks.
- `SessionSummaryCoordinator` owns request generations, cancellation, the in-memory cache, operational errors, and stale-result rejection.
- `ACPSessionSummaryControl` owns the toolbar trigger and popover presentation.
- `ACPSessionSummaryPopover` renders progress, results, errors, and Refresh.

Cache entries are keyed by `ACPSession.incarnation`, not the persisted session ID, so a replacement session cannot inherit an old result. A captured source revision contains the incarnation, `ACPTranscript.messagesGeneration`, current goal value, current plan value, and the relevant idle/work counters. Publication requires every captured value to still match.

Subscribe to the session's synchronous activity and teardown signals before starting generation. Activity increments the request generation, cancels the caller task, clears the cache, and publishes a presentation-close signal. The UI must not be the only owner of cancellation because activity can begin while the popover is being dismissed.

## Context construction

Build context on the main actor from complete transcript turns. Include only ordinary user prose and assistant prose. Exclude delegated prompts and all raw tool, thought, attachment, file-edit, permission, question, notice, and hidden-provider material.

Include the current deterministic goal and plan as separately labelled data when present. Goal and plan are not model instructions. The system prompt states that every supplied value is untrusted data and must only be summarized.

Use the existing 128 KiB source ceiling and an 8,192-token rendered-input ceiling. Keep complete turns newest-first until they fit, then restore chronological order. Never truncate an individual message. Prefer the current goal, current plan, and newest complete turn over older turns. If the complete input cannot fit, fail without generation.

The context snapshot records whether older turns were omitted. That fact is deterministic UI metadata and is not inferred by the model.

## Output contract and safety

Request one JSON object with exactly these keys:

```json
{
  "goal": "string or null",
  "completed": ["string"],
  "blockers": ["string"],
  "next_action": "string or null"
}
```

Reject duplicate or additional keys, invalid JSON, wrong types, control characters, markup, embedded URLs, multiline values, or output outside the byte limit. Bound each string to 280 Unicode characters and each array to five items. Require at least one non-empty field. Generate no more than 512 tokens with temperature zero and the pinned non-thinking chat template.

The summary prompt forbids invented facts, credentials, claims of completed actions, permission answers, consequential consent, and instructions to disclose secrets or perform destructive/irreversible actions. Feature-local output policy rejects recognized credential values and unsafe next-action text. It may reuse small tested credential/action matchers, but it does not call the suggestion policy as a whole because a descriptive summary and a proposed user reply have different contracts.

The displayed summary is labelled as locally generated and advisory. Deterministic goal and plan data remain available through their existing UI and are not overwritten.

## Request flow

1. The toolbar control verifies the feature is enabled, supported, installed, ready, and the session is idle.
2. Opening the popover asks the coordinator for the cached entry for the current incarnation. A current cached entry renders immediately.
3. Without a cache, the coordinator captures the source revision and builds/fits the context.
4. The popover renders progress while the coordinator submits a user-initiated job to the shared engine.
5. The engine cancels and drains lower-priority automatic suggestion work, loads the verified model if needed, and runs bounded generation off the main actor.
6. The summary policy parses and validates raw output.
7. The coordinator rechecks request generation, session incarnation, transcript generation, goal, plan, and idle facts before caching and publishing.
8. Closing the popover cancels unfinished generation. New session activity additionally clears any cached result and forces the popover closed.
9. Idle unload and memory-pressure behavior remain owned by the shared engine.

## Errors and recovery

Distinguish operational failures from rejected model output. Installation, verification, unsupported-hardware, load, timeout, and memory-pressure failures use explicit UI copy and never masquerade as an empty summary. Invalid or unsafe output reports that Alas could not produce a usable summary without exposing raw model text.

Retry is always explicit. Summary generation does not use the next-prompt rule that pauses after two failures. A failed summary releases its engine job and lease normally, leaving next-prompt behavior unchanged.

A save failure while disabling Session summaries suppresses the capability for the current process, explains that relaunch may restore the persisted setting, and offers Retry Disable. This mirrors the corrected next-prompt behavior.

## Accessibility

The toolbar control has a stable accessibility identifier, label, help, enabled state, and model-status value. The popover announces loading, failure, and completion changes without moving focus into generated text automatically.

Each summary section uses a heading and selectable body/list text. Refresh and Retry have distinct labels. Escape closes the popover and cancels unfinished generation. Reduced-motion settings apply to progress and active-control styling.

## Verification

Pure Swift Testing suites cover:

- Context filtering, chronological ordering, complete-turn truncation, goal/plan priority, partial-context metadata, and token fitting.
- Exact JSON shape, duplicate/additional keys, Unicode bounds, item limits, credential rejection, unsafe next actions, and abstention.
- Shared-engine serialization, explicit-over-automatic priority, cancellation drain, lease lifetime, deadline, idle unload, and independent feature failure state.
- Cache reuse, incarnation isolation, transcript/goal/plan stale-result rejection, synchronous activity invalidation, popover-close cancellation, refresh failure retaining the prior result, and teardown cleanup.
- Independent setting decoding, consent/install sharing, failed disable persistence, removal eligibility, and unsupported startup avoiding model inspection.
- Toolbar visibility/enabled states, popover loading/result/error states, section omission, partial-context label, Escape, and accessibility labels.
- Existing next-prompt focused suites after the engine extraction.

Run the affected focused suites rather than the complete local test plan. Because the shared MLX path and project configuration change, repeat Debug and Release builds for arm64 and x86_64 and regenerate `Alas.xcodeproj` with `xcodegen` if `project.yml` changes.

Manual verification uses a disposable session and covers first generation, reopen from memory, Refresh, refresh failure, closing during generation, new activity forcing dismissal, relaunch requiring regeneration, next-prompt preemption, model removal rules, VoiceOver reading order, and unsupported/disabled toolbar absence. Keep Session summaries default-off and Debug-only until native evaluation confirms grounded summaries and acceptable memory behavior.
