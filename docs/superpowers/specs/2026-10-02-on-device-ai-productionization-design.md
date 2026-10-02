# Production on-device AI settings

Status: provider split, visual direction, and written specification approved. Implementation plan written and self-reviewed; product-code changes await plan review and execution-method selection.

## Intent

Make Alas's existing built-in AI helpers accessible in production, with one cohesive settings page, accurate Apple Intelligence availability, and explicit management of the optional downloaded model.

The user approved preserving the current provider split. They also approved the browser mockup of the On-device AI page. This change is not configuration for external coding agents and does not add Apple Intelligence generation to summaries or next-prompt suggestions.

Success means a user can understand which helpers work without a download, install and manage one model without enabling an unrelated feature, and control automatic processing from ordinary settings.

## Current behavior

- `AdvancedPane` hosts `LocalTextModelSettings` under Experimental. The Debug section is hidden without the `~/.alas/.debug` marker.
- `ChatPane` separately hosts the on-device fallback-title preference.
- The MLX engine already permits Debug and Release on supported Apple silicon hardware. Moving the settings does not require removing an engine build gate.
- Next-prompt suggestions and session summaries currently own installation and MLX consent. Four other helpers borrow permission through their runtime flags.
- Apple Intelligence worktree names currently depend on the chat-title setting. The downloaded-model naming path instead depends on summaries or suggestions.
- Failure briefs default on, but their only preference control is hidden in Debug.
- One pinned Qwen model is shared by all MLX callers. Existing storage provides verification, progress, cancellation, leases, and cross-process removal protection.

## Scope

Promote the settings and management flow for these existing capabilities:

1. Chat titles.
2. Issue-based worktree names.
3. Run failure briefs.
4. Merge-conflict explanations.
5. Session summaries.
6. Next-prompt suggestions.

Separate permission to use the local model from individual feature preferences. Remove implicit dependence on the summaries and suggestions flags.

Do not add cloud providers, model selection, automatic downloads, telemetry, model benchmarking infrastructure, a chat assistant, or new inference prompts. Do not change dictation settings or external-agent configuration.

## Settings placement and appearance

Add an always-visible `On-device AI` section to `SettingsSection` and the existing Settings window. Preserve General-first and alphabetical navigation. Use a chip icon so the page is distinguishable from Agents.

Keep the existing 880-point window, 200-point sidebar, 680-point content pane, and scrollable page. Reuse `SettingsGroup`, `SettingsRow`, `AlasToggle`, `AlasButton`, theme tokens, and existing typography rather than creating a second settings convention.

The page contains, in order:

1. Title `On-device AI` and subtitle `Built-in helpers that run on this Mac.`
2. A compact Apple Intelligence availability panel.
3. A Helpers group for titles, worktree names, failure briefs, and conflict explanations.
4. A Local model group with one management panel and an `Optional download` label.
5. The local inference memory note.
6. Session summaries and next-prompt suggestions preferences.
7. A short privacy note distinguishing built-in helpers from coding agents.

Panels use the existing themed backgrounds, subtle borders, small corner radii, and restrained status colors. Status must include text, not color alone. Rows retain the app's two-column label/control layout.

The approved local mockup is `.superpowers/brainstorm/99272-1790956132/content/on-device-ai-settings.html`. It is an ignored design artifact, not product code. Its state selectors, comparison cards, theme switch, sample download progress, and preview-only notices do not ship.

### Alternatives considered

- Put everything in Chat: fewer navigation sections, but inaccurate for worktrees, conflicts, and run scripts.
- Distribute preferences across Chat, Worktrees, Changes, and a shared downloader: closer to each workflow, but makes model consent and availability hard to find.
- Dedicated On-device AI page: selected because these helpers share provider availability and one downloaded model while spanning multiple workflows.

## Provider policy

Preserve the existing generation behavior, including its feature-specific fallback conditions.

| Helper | Apple Intelligence | Downloaded model |
| --- | --- | --- |
| Chat titles | First choice when available and the title preference is enabled | Fallback only when Apple Intelligence is unavailable; do not add a retry after an invalid or failed Apple answer |
| Worktree names | First choice when available and naming is enabled | Existing router fallback when Apple is unavailable or produces no accepted result |
| Failure briefs | First choice when available and briefs are enabled | Existing router fallback when Apple is unavailable or produces no accepted result |
| Conflict explanations | First choice on explicit request | Existing router fallback when Apple is unavailable or produces no accepted result |
| Session summaries | Not used | Required |
| Next-prompt suggestions | Not used | Required |

The settings overview says Apple Intelligence is used first for the helpers that support it. It must not imply all six features can use Apple Intelligence or that a model download is required for Apple-backed helpers.

Local-model fallback requires all of: supported hardware, saved user permission to use the model, a verified ready installation, and no shutdown or removal operation. It does not require summaries or suggestions to be enabled.

Preserve each feature's existing input limits, safety checks, parsers, priorities, deadlines, cancellation, caching, and eligibility. Titles generated by the coding agent continue to take precedence. Suggestions remain insert-for-review only and never submit automatically.

## Apple Intelligence availability

Expose one reasoned availability value shared by the settings presentation and existing Apple availability checks. Distinguish:

- Available and current locale supported.
- macOS earlier than 26.
- Device not eligible.
- Apple Intelligence turned off.
- System model not ready.
- Current locale unsupported.
- An unrecognized system unavailability reason.

Read the system's actual model availability and locale support. Do not infer eligibility from architecture alone or label a not-ready system model as a failed Alas download.

Refresh when the pane appears and when the app becomes active so changes in System Settings are reflected without relaunch. Generation still rechecks availability at execution time.

Use `Open System Settings` only when that action can help, such as Apple Intelligence being turned off or its model preparing. Unsupported OS, hardware, or locale messages should explain the limitation. Use a supported Settings URL when available, otherwise open System Settings without promising a precise destination.

When Apple Intelligence is available but the local model is absent, show `Apple Intelligence first`. With an allowed ready model, show `Apple Intelligence first` and `Local fallback ready`. With Apple unavailable and the local model usable, show `Using the local model`. If neither can run, explain `No model available` and the applicable remedy.

Feature switches represent saved preferences, not instantaneous model readiness. Do not render an enabled preference as off because its provider is temporarily unavailable.

## Feature preferences

- Chat titles keeps `harness.acpLocalTitlesEnabled` and its current default.
- Worktree names gains an independent saved `issueWorktreeNameSuggestionsEnabled` preference. It gates both Apple and MLX naming so turning off titles no longer changes worktree naming.
- Failure briefs keeps `runFailureBriefsEnabled` and its current default.
- Conflict explanations remain user-initiated. Show their availability instead of adding an unnecessary automatic-processing switch.
- Session summaries keeps `sessionSummariesEnabled`, default off for new users.
- Next-prompt suggestions keeps `nextPromptSuggestionsEnabled`, default off for new users.

Each preference row names the purpose, not the implementation library. Local-only rows say `Requires the local model` when not installed, `Available after verification` during provisioning, and `Turn on Use local model` when installed but disallowed.

Enabling a local-only feature never installs a model. Its disabled/off control points the user to the model panel. An already-enabled preference can always be turned off, including during download, provider unavailability, or a retry-required runtime state.

Keep persistence failures explicit. If a disable cannot be saved, suppress that feature immediately in the running process and expose retry, without reporting that the persistent setting changed successfully.

## Local-model consent and management

Add one saved `localTextModelEnabled` preference for permission to use the downloaded model. New users start with it off. Installation state remains separate from permission and per-feature preferences.

### Not installed

Show Qwen3, its 4B parameter/4-bit identity, manifest-derived download size, what it enables, and `Download…`.

Confirmation explains:

- Model files come from Hugging Face.
- Approximately 2.3 GB will be downloaded, using the bundled manifest for displayed size.
- Inference runs on this Mac and can use several GB of memory.
- Some process memory may remain allocated after unload.
- Downloading grants permission to use this model for built-in helpers.
- Summaries and suggestions are separate preferences and are not turned on by the download.

Accepting confirmation first saves local-model permission, then starts the existing verified installation. If permission cannot be saved, do not start downloading. Cancelling confirmation changes nothing.

### Downloading and verifying

Show bytes received and expected, a progress bar with an accessibility label, and Cancel. Verification has its own indeterminate status. Download, cancellation, or verification does not interrupt the Apple-backed routes.

Closing Settings does not cancel an explicitly accepted download. Cancel stops the transfer but does not change feature preferences or destroy a previously verified model. Cancelled or failed first-time installation leaves permission saved; no startup or feature action silently restarts the download.

### Installed

Show installed/verified status, `Use local model`, and `Remove…`. A ready installation does not imply permission to use it.

Turning Use local model off revokes local inference immediately, cancels all MLX-dependent callers, drains native work, and unloads the model. It does not disable Apple-backed helpers, erase files, or rewrite feature preferences. If saving the revocation fails, permission stays suppressed in this process and retry is visible.

Turning it back on verifies readiness and restores only features whose saved preferences are enabled. It does not download missing assets.

### Removal

Confirmation explains freed storage, loss of local-only capabilities, and loss of fallback without disabling available Apple Intelligence helpers.

After confirmation, save local-model permission off and suppress new MLX work before cancellation and native drain. If saving that change fails, keep runtime permission suppressed, show retry, and do not proceed with file deletion.

Once this process has drained, use the existing exclusive lease check to remove the shared files. Another process's lease still blocks removal with an actionable message. Keep feature preferences unchanged, show the absent-model prerequisite, and provide Retry Removal after an operational failure.

The old rule requiring both summaries and suggestions to be disabled is obsolete. Remove it; explicit model permission now governs all local callers.

### Errors and unsupported hardware

Use the existing model failure classification and settings messages for connection, space, integrity, filesystem, manifest, busy, and in-use failures. Keep errors beside the model operation and expose the appropriate retry action.

A failed model operation must not claim Apple Intelligence is unavailable. A paused suggestion runtime must not claim the installed model is corrupt or disable other helpers.

On unsupported local-model hardware, explain the Apple silicon/Metal requirement and disable download/use actions. Continue showing Apple Intelligence availability independently and allow management/removal of any existing files where safe.

## Migration

Keep existing settings keys and model storage paths so existing installations are reused. Do not move or redownload the pinned model.

When `localTextModelEnabled` is missing from an old configuration, derive it from `nextPromptSuggestionsEnabled || sessionSummariesEnabled`. Those flags represented the old explicit model consent. Once the new key exists, its value takes precedence, including false.

When `issueWorktreeNameSuggestionsEnabled` is missing, derive it from the prior title preference or prior local-model feature consent. This preserves naming for users who had either old naming route enabled. New configurations default naming on, consistent with the currently enabled Apple title/naming defaults.

Preserve all existing feature preferences. Do not opt previous users into summaries or suggestions. Loading migrated config may inspect an installed model if permission allows it, but never starts a download.

Remove AI management from Debug and the title preference from Chat. Do not leave duplicate controls, deprecated preference aliases, or old explanatory copy. Debug's unrelated experimental controls remain untouched.

## Ownership and affected modules

`AppState` remains the owner of config, model-operation tasks, status observations, and feature coordinators. Keep those responsibilities in the existing local-text settings extensions; rename the suggestions-named shared lifecycle extension to reflect model-wide ownership during the cutover.

`LocalTextModelStore` remains responsible for install, verification, cancellation, leases, and removal. `LocalTextInferenceEngine` remains responsible for serialized native generation, deadlines, drain, idle unload, and memory-pressure unload. No second downloader or generic feature/provider framework is needed.

The settings view consumes reasoned Apple availability, existing model state, explicit model permission, and per-feature preferences. It invokes AppState actions rather than owning inference or provisioning tasks.

Update the existing title/naming/brief/conflict availability predicates to depend on explicit permission, not borrowed summaries/suggestions consent. Turning a feature off cancels only that feature's work. Turning model permission off cancels every local-model caller while keeping Apple-only work independent.

Primary affected files are Settings navigation/window/Advanced/Chat/model settings; AppState local-text lifecycle and summary extensions; AppConfig; Apple availability helpers and existing provider factories; dependent caller availability checks; related focused suites and user documentation. Regenerate the Xcode project only if project configuration or explicit file membership requires it.

## Verification and release acceptance

Extend existing Swift Testing suites only where behavior can silently regress:

- Absent-key migration, explicit-false precedence, and preservation of unrelated config.
- Fallback remains usable with summaries and suggestions both off when model permission is on.
- Turning titles off does not disable independently enabled worktree naming.
- Revoking permission or removing the model prevents late local results and new local requests, without stopping Apple-backed helpers.
- Enabling a feature, launch, and retrying runtime inference do not initiate a download.
- Removal drains this process, respects another process's lease, and leaves other files and preferences intact.
- Save failure does not falsely report successful revocation or trigger a download/deletion.

Reuse existing model-store, lease, provider-routing, settings, and coordinator suites. Do not add tests for labels, styling, default declarations, subview existence, or forwarding.

Actual app verification must cover a production-visible page without the Debug marker, light/dark themes, scroll/layout, Apple availability changes, consent cancel/accept, real progress/cancel/retry/verification, permission off/on, removal/in-use failure, and feature entry points. Check keyboard access and accessibility status text.

Before releasing the promoted local-only features, run native generation in a disposable session with public/synthetic text, including a grounded summary and a reviewed suggestion. Record memory and cancellation behavior. The older summary evaluation document reports native generation blocked at the time; it is not evidence of current model output quality.

Run focused affected suites and the required production build, not the whole local test plan by default. New provider generation is out of scope, but unchanged inference must still be exercised end to end before calling the productionization complete.

## Evidence collected for this design

- Read-only source inspection confirms the existing provider split, model lifecycle, release support, and hidden settings coupling.
- A direct Foundation Models availability probe reported `available` with the current locale supported. It did not generate text.
- The browser mockup was rendered and visually inspected in dark and light themes.
- Mockup interactions exercised download confirmation, download progress, cancellation, installed-model permission off, Apple-unavailable fallback messaging, summary toggle, removal confirmation, Escape dismissal, and removal returning to the absent state. No JavaScript errors were reported in the inspected run.
- No actual model download, native generation, application preference change, app build, or Swift test run was performed for this design.

## Review handoff

Review this specification before writing the implementation plan. Visual approval authorizes the specification, not product-code changes. The implementation plan follows written-spec approval.
