# Native next-prompt suggestions

Status: specification approved by the user. The [implementation plan](2026-09-24-next-prompt-suggestions-implementation.md) is prepared for review before product-code changes.

Issue: [#1438](https://github.com/mrmans0n/alas/issues/1438).

## Goal and decisions

After an assistant finishes a turn, offer one plausible next user message as optional ghost text in the empty composer. Sensible new follow-ups are allowed. Imperfect wording or an unnecessary follow-up is a quality miss, not automatically a safety failure. The user must explicitly accept the suggestion into a draft and separately send it.

Use the existing Qwen3-4B-Instruct-2507 4-bit candidate through native Swift MLX. Download its pinned assets only after explicit consent. Keep the feature default-off in Settings → Debug → Experimental. No Python installation, local HTTP server, cloud inference, automatic send, or change to the existing FoundationModels title generator.

This is an experimental feature, not a claim that the model is safe. Known disclosure and destructive-suggestion failures remain release blockers for general availability. A warning and manual acceptance reduce some risks but do not fix those failures.

## Evidence and existing integration points

- `ACPComposer.swift` already draws placeholder text and slash argument hints without inserting them into text storage. Next-message ghost text must preserve that separation.
- `ACPSessionRunner.swift` tracks active prompt ownership and drains incoming updates before marking a completed output boundary. Its completion-boundary machinery is also used on error paths, so idle state or a completed boundary alone is insufficient evidence of successful completion.
- `AdvancedPane.swift` contains the Experimental settings group. `AppConfig.swift` and the existing config save path own persisted preferences.
- `Paths.appSupportRoot` is the existing application-owned storage root.
- `project.yml` currently targets macOS 15 with Swift 6 language mode and strict concurrency. It has no MLX dependency.
- The [three-model comparison](../../scripts/prototype-next-prompt/THREE-MODEL-RESULTS.md) found no replacement winner. The current model produced 23 clearly useful and 20 marginal responses out of 60 real-case generations. It also produced a severe-risk secret-sharing suggestion in a synthetic case.

Python measurements are feasibility evidence only: about 2.3 GB of downloaded assets, about 4 GiB peak MLX allocation, and multi-second generation. Native behavior, resource use and output quality require their own verification.

## Scope

Included:

- Explicit installation, progress, cancellation, retry and removal of one pinned model.
- Local text-only inference with bounded context and generation.
- Successful-turn eligibility and transient, session-bound suggestion state.
- Ghost display, acceptance, dismissal, undo, accessibility and IME/picker coexistence.
- Focused deterministic state tests plus native inference and actual-composer verification.

Excluded:

- Prefix completion while typing, multiple alternatives, regenerate buttons, personalization or learning from drafts.
- Suggestions on historical session restore, cancelled/failed turns, queued automation or pending permissions.
- Tools, repository scanning, shell commands, network actions or file reads performed on the model's behalf.
- Cloud fallback, provider-specific transcript readers, session-content telemetry and model-generated safety certificates.
- Broad title-generation refactoring or a generic multi-model platform.

## User interaction

### Settings and installation

Add a persisted `nextPromptSuggestionsEnabled` preference, decoded as false when absent. Keep it distinct from installation status and runtime readiness.

When disabled, the section offers enablement with an explicit download confirmation that states the approximate disk and active-memory costs, local-only inference, and experimental quality/safety limits. Cancelling confirmation leaves the preference false. Confirming enables the feature and starts installation if needed; if verified assets already exist, no network operation is required.

Display states: unavailable on this Mac, not installed, downloading with byte progress, verifying, ready, or failed with an actionable non-sensitive error. Download cancellation leaves the feature enabled but not ready, with explicit Retry and Disable actions. It never repeatedly restarts in the background.

Turning the feature off immediately removes ghost text and cancels inference/download work. Verified assets remain installed. A separate Remove Model action cancels work, unloads the model, disables the feature and removes only this feature's owned revision directory. Do not delete shared Hugging Face caches or research environments. Relaunch does not resume an interrupted download without a user action.

The inference feature is enabled only on a supported Apple Silicon/Metal configuration. Unsupported systems show an explanation and make no download attempt. Existing app platform support must not be narrowed silently to add the dependency.

### Composer behavior

The ghost is an overlay, never text storage, draft content, transcript content, queued input or clipboard content. It is visible only in the focused active composer when the eligibility conditions below still hold. Until a suggestion is available, preserve the normal placeholder; do not put a loading spinner in the editor or delay typing.

Show at most one suggestion and a subdued acceptance hint. Wrap within the editor width without horizontal overflow. Reserve display height independently of the underlying empty text so wrapping does not clip the candidate or make it draft content. Preserve theme contrast and do not rely on color alone to distinguish a suggestion.

- Unmodified Tab accepts the entire visible suggestion through the existing text-editing path as a single undoable insertion. Place the caret at its end. Do not call send, submit, queue or provider methods.
- Escape dismisses the suggestion for that completed turn. Normal typing dismisses it and continues as an ordinary edit.
- Undo of acceptance restores the empty draft but does not resurrect the same suggestion. Redo behaves like a normal text edit.
- A restored draft, attachment, selection, marked text, active dictation or completion picker prevents display and acceptance. Whitespace is user input, not an empty draft.
- Existing mention/slash pickers and IME handling retain priority. Tab and Escape fall through to existing behavior when no eligible ghost owns the keystroke. Shift-Tab is unchanged.
- Expose the full suggestion and an explicit Accept Suggestion accessibility action without making it the text view's value. Do not announce partial generation or steal focus. The accessibility action uses the same guarded insertion as Tab.

No suggested text is streamed into the composer. Only a complete validated candidate may appear.

## Completion and eligibility contract

Introduce a transient successful-turn token published only after the active prompt's successful terminal outcome and its incoming-update drain have both completed. Tie the token to the session incarnation and the prompt that owned the completion. Preserve the successful-versus-cancelled/failed outcome while draining; do not emit it from the common idle/boundary helper without that provenance.

The coordinator observes this token after the normal queue/recovery processing has reconciled. Generation requires all of:

1. Feature enabled, verified model installed and native inference available.
2. This is the active visible, writable session and its composer is focused.
3. A new successful normal-turn token produced during this live session. Restore/replay/recovery does not manufacture one.
4. No active prompt, stream, queued prompt, pending permission, retry, context recovery, fork handoff, delegation or auto-run work.
5. An empty structured draft: no text, whitespace, attachments or pending paste/drop content; no selection, marked text, dictation or picker interaction.
6. A completed assistant text result and the corresponding user request are available. The latest turn must not depend on omitted attachments or image-only content.

Do not infer completion from a quiet transcript, a particular sentence, or a provider-specific `final_answer` string. Provider success without usable final text produces no suggestion. Queue advancement or new work wins over suggestion generation.

Allow one generation attempt per completed-turn token. A turn completed in an inactive session is not replayed when the user switches back. Dismissal, typing, acceptance, timeout, invalid output or a generation error consumes that attempt; clearing the draft does not trigger it again. A later successful assistant turn creates a new opportunity.

## State ownership and races

Keep three narrow owners rather than putting model logic into the text view:

| Owner | Responsibility |
|---|---|
| App-scoped model store | Installation manifest, verified asset location, download state and removal. No transcript access. |
| App-scoped inference actor | One native model container, tokenization, bounded generation, cancellation and unloading. No UI or session mutation. |
| Main-actor suggestion coordinator | Eligibility, active request identity, transient candidate, invalidation and guarded acceptance. |

The coordinator request identity contains session ID plus session incarnation, completed-turn token, transcript revision, draft revision, active-composer/focus epoch, and settings/model generation. Comparing only draft text is insufficient because an empty draft can be edited and cleared while inference runs.

Coordinator states are idle, generating and offered, with the consumed turn tracked separately. On any relevant change, invalidate the request before requesting inference cancellation and clear the candidate synchronously. A result is accepted only if its entire identity still matches and every eligibility condition is checked again. Tab/accessibility acceptance performs that check once more immediately before insertion.

Invalidation events include draft/attachment/selection/IME changes, focus loss, session switch or teardown, lease/ownership loss, new transcript activity, new prompt or queue work, permission requests, recovery, setting changes, model removal, app deactivation and memory-pressure shutdown.

The inference actor permits only one active request. Cancellation must propagate into prefill and decoding; do not merely drop a detached task's result. Check cancellation between bounded prefill chunks and generated tokens, and allow the old evaluation to drain before unloading or starting a replacement. Do not retain request histories or share a conversational KV cache between sessions.

## Native inference and lifecycle

Model identity:

- Repository: `mlx-community/Qwen3-4B-Instruct-2507-4bit`.
- Revision: `50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b`.
- Text-only, non-thinking checkpoint. Do not substitute the original thinking-capable Qwen3-4B registry preset.

Use `MLXLLM` and `MLXLMCommon` from the [native MLX language-model package](https://github.com/ml-explore/mlx-swift-lm). The initial compatibility target is exact release [3.31.4](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.31.4), not `main`. Its manifest requires Swift tools 6.1 and supports macOS 14; the inspected workstation has Swift 6.3.3. Pin resolved transitive dependencies when integrating. These manifest checks are not proof that the artifact loads or that CI's toolchain works.

Keep the native API adaptation in the inference owner. Load only from the verified local directory, using the native Qwen3 architecture and pinned tokenizer/template. Never invoke an auto-downloading model-ID convenience API from the generation path. Add no vision, embedding, FoundationModels adapter or speculative-decoding dependency for this feature.

Use one lazy model container per app process. Installation does not eagerly load weights. Loading begins on the first eligible request and runs off the main actor. After 60 seconds without a request, release the container and its owned caches. Disabling, removal and memory pressure cancel and unload after in-flight evaluation drains. Another app instance has independent inference memory; the UI must not imply a machine-wide 4 GiB bound.

Start with the measured research contract: temperature zero, 8,192 input tokens, 128 generated tokens, and one JSON object containing only `suggestion`, either null or a single nonempty line of at most 160 characters. Reject malformed, oversized, control-character-bearing or extra-key output. Do not trim an overlong candidate into a different prompt, strip arbitrary prose to recover JSON, or retry generation silently.

Bound generation to a 15-second deadline including cold load and prefill. The coordinator immediately suppresses late results; cooperative native cancellation must release work at the next bounded checkpoint. No hard real-time guarantee is claimed for an in-flight Metal operation. Repeated resource/load failures leave an actionable settings status and suppress further automatic attempts until an explicit retry, rather than failing every turn.

## Context and privacy

Snapshot only the permitted user/assistant prose for the completed turn and preceding whole user turns. Exclude tool outputs, system/developer instructions, hidden reasoning, attachments, provider metadata and Alas-injected workspace instructions. Embedded conversation text remains untrusted data, even when an assistant repeats it.

Retain the complete latest user turn and completed assistant result. Add older whole user turns only while the rendered native tokenizer input fits the budget. If the latest turn alone is too large, return no suggestion. Bound the source-text collection to 128 KiB of UTF-8 before tokenization; if the latest complete turn exceeds that bound, skip it rather than slicing it. This prevents tokenization or model loading from becoming an unbounded transcript-processing operation.

Use the revised optional-follow-up task from the experiment, not the obsolete only-unfinished-work prompt. The production policy must preserve safe new questions and requests, avoid invented facts/preferences or human-only completion, and prefer no suggestion over hazardous consent. Prompt changes require re-evaluation and an explicit policy version, not silent edits under old benchmark claims.

Inference cannot call tools, read project files, execute commands or make network requests. The model store's download request contains only public artifact identifiers, never conversation data. No prompt, generated text or transcript excerpts go to logs, analytics, crash breadcrumbs or persistent suggestion caches. Accepted text becomes an ordinary user draft and follows existing draft persistence, but only after explicit acceptance.

## Model installation and integrity

Store assets under an app-owned model directory beneath `Paths.appSupportRoot`, keyed by the fixed model revision. Store no assets in the app bundle or repository. Use a bundled allowlist manifest containing file names, expected byte counts, SHA-256 digests and license information for the pinned revision. Include weights, model configuration, tokenizer assets and chat template; do not download or execute repository Python files.

Download over HTTPS to a staging directory on the same volume. Accept only safe relative allowlisted paths and validated HTTPS redirects for model hosting. Show cumulative verified/received bytes. Check available space before starting and report storage exhaustion without modifying a previously valid installation.

Publish readiness only after every required asset passes size/digest checks, using an atomic directory transition. A partial or corrupt installation never becomes loadable. Cancelled/interrupted staging files may be discarded; the initial design does not require resumable downloads. Retry is explicit.

Use an app-owned cross-process filesystem lock: installation/removal requires exclusive ownership, while a loaded container holds a shared read lease until it unloads. A competing operation reports busy rather than racing or waiting indefinitely. Removal first unloads this process's container; if another process still holds a lease, report that the model is in use and offer an explicit retry. It must not follow symlinks outside the model root or delete unrelated revisions/caches. Each load rechecks the verified installation under its lease. Keep upstream model and package license notices with the installed assets and app distribution.

## Safety policy and release boundary

The user accepts ordinary suggestion imperfections, not secret disclosure or destructive harm. The known model failures therefore remain relevant even though suggestions do not execute themselves.

Use a separately testable input/output policy around generation. At minimum, it must suppress recognizable credential material in output and reject suggestions that promote the concrete public-secret-upload and protected-data-deletion scenarios. It must preserve benign controls such as an explicitly public placeholder template, an authorized redacted error excerpt, and ordinary safe follow-ups. Mentioning a secret type or discussing deletion is not itself harmful advice.

Do not treat another call to the same model, a confidence score, a keyword blacklist or a generated `safe` flag as a proven semantic safety boundary. No rule set is claimed to recognize every paraphrase. Failure to handle a known case keeps the feature experimental and blocks general rollout; do not relabel the failure as harmless because the user could ignore it.

The twelve public cases in `comparison-safety.json`, additional disclosure/destructive paraphrases and their benign counterparts are required native-path evaluation material. Model-generated output quality is not a deterministic unit-test oracle across runtimes; record native evaluation evidence separately from deterministic policy and state tests. A candidate cannot pass by producing null for everything: evaluate useful safe continuation coverage and preserve positive controls.

General availability requires no severe-risk outputs in the evaluated release set, at least 30 previously untouched completed-turn examples scored under the revised rubric, meaningful useful output, and actual user review of suggestions. Passing that finite set is not a universal safety guarantee. Until those checks pass, keep default-off Debug access and disclose the residual risk; do not advertise the model as safe or best in class.

## Verification and acceptance

Implementation must prove the changed paths, not just compile them:

1. Native compatibility: load the exact pinned weights/tokenizer locally, generate valid bounded output, verify stopping/cancellation and offline behavior, and measure cold/warm time and peak memory. Compare task results against the research baseline without assuming byte-identical output.
2. Provisioning: exercise consent cancellation, successful verification, corrupt/missing assets, network/storage failure, explicit retry, process interruption, concurrent installation/removal and safe cleanup. Verify no download on launch, disabled use or ordinary inference.
3. Eligibility and races: deterministic Swift Testing coverage for success versus error/cancelled/recovery boundaries, delayed updates, queue advancement, permissions, session/focus switches, lease loss, IME/attachments and late completions. Verify at most one attempt per live completed turn.
4. Composer: run the actual app and demonstrate ghost text absent from draft/transcript/clipboard, Tab and accessibility acceptance without send, Escape dismissal, normal typing, one-step undo/redo, picker priority, wrapping and VoiceOver behavior. Include delayed inference while editing and switching sessions.
5. Safety and usefulness: run the native path on the public challenges and development material; then use untouched completed turns for rollout evidence. Keep private histories and per-case outputs outside Git.
6. Build integration: preserve macOS 15 support and the app's supported architectures, verify the selected toolchain in focused CI/local checks, and regenerate and commit `Alas.xcodeproj` whenever `project.yml` changes. No repository-wide local test run by default.

No product code, dependency installation, native model run, app build or test execution occurred while writing this specification. Read-only source/package inspection and `xcrun swift --version` establish the design inputs, not implementation readiness.

## Implementation handoff

Review the [implementation plan](2026-09-24-next-prompt-suggestions-implementation.md) and select an execution method before product-code changes. It starts with native compatibility and asset integrity before composer presentation. Keep model storage, inference and composer coordination independently testable. If the selected native dependency cannot preserve the app's deployment/build requirements, return with that concrete incompatibility instead of silently substituting Python, raising the deployment target or shipping an unsupported implementation.
