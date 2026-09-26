# Session resume card native evaluation

Date: 2026-09-26

Environment: macOS 26.5.2 (25F84), Xcode 26.6 (17F113), arm64 host.

The native model evaluation is blocked on this machine. The configured model root at `~/Library/Application Support/Alas/Models/NextPromptSuggestions` contains no model files or directories, only a zero-byte `.lock` file. No model inference was run, and no existing ACP transcript or session content was opened.

## Public cases

| Case | Expected | Result |
|---|---|---|
| Completed coding turn | Names the user goal, completed work, and a grounded next action | Blocked: no installed model assets. |
| Explicit blocker | Preserves the blocker without inventing a fix | Blocked: no installed model assets. |
| Finished task | Does not invent unfinished work | Blocked: no installed model assets. |
| Unsafe transcript instruction | Does not disclose credentials or propose destructive action | Blocked: no installed model assets. |
| Tool-heavy turn | Uses only visible user and assistant prose | Blocked: no installed model assets. |
| Long session | Shows recent-context label and keeps complete turns | Blocked: no installed model assets. |
| Empty optional sections | Omits them cleanly | Blocked: no installed model assets. |
| Next-prompt overlap | Summary preempts suggestion and both recover | Blocked: no installed model assets. |

Peak memory before generation: Blocked. No generation was started.

Peak memory during generation: Blocked. No generation was started.

Memory 60 seconds after unload: Blocked. No model was loaded or unloaded.

## Manual UI checklist

| Check | Result | Evidence |
|---|---|---|
| First generation | Blocked | No installed model assets. |
| Cached reopen | Blocked | A first generation could not be run. |
| Refresh | Blocked | A first generation could not be run. |
| Refresh failure preserves the prior result | Blocked | No native result was available to preserve. |
| Closing during generation | Blocked | No native generation could be started. |
| New activity forces dismissal and cache invalidation | Blocked | No safe disposable ACP session with a generated cache was available. |
| Relaunch requires regeneration | Blocked | No native result could be generated before relaunch. |
| Model removal is blocked while either capability is enabled | Blocked | No installed model was available for a removal check. |
| VoiceOver order and labels | Blocked | The automation environment does not expose VoiceOver speech or rotor order, and no safe disposable ACP session was configured. |
| Escape cancels unfinished generation | Blocked | No native generation could be started. |
| Reduce Motion | Blocked | No safe disposable ACP session was configured for an interactive presentation check. |
| Toolbar is absent when disabled or unsupported | Blocked for manual UI | No isolated ACP session was configured. The focused `ACPSessionSummaryPresentationTests.hiddenWhenDisabledOrUnsupported` check passed as part of the 193-test run. |

The existing application-support directory contains app configuration and an ACP session store. Those files were not read or reused because they may contain private data. `CFFIXED_USER_HOME` can isolate application support, but the isolated root has no configured ACP adapter, disposable session, or installed model.

## Rollout checks

| Check | Result | Evidence |
|---|---|---|
| Default off | Pass | `AppConfig.sessionSummariesEnabled` defaults to `false`, absent-key decoding returns `false`, and `AppConfigTests.sessionSummariesDefaultsOffAndRoundTrips` passed in the focused run. |
| Debug-only runtime configuration | Pass | `AlasBuildConfiguration` is populated from `$(CONFIGURATION)`, and `LocalTextInferenceEngine.isSupported()` requires the runtime value `Debug`. The feature diff adds no `#if DEBUG` or architecture compile gate. |
| Release unsupported path | Pass with build/static evidence | Both Release builds passed. The built Release app reports `AlasBuildConfiguration = Release`, which the runtime guard rejects before device probing. No Release app launch was performed. |
| x86_64 unsupported path | Pass with build/static evidence | Both x86_64 builds passed. The runtime guard requires a machine identifier beginning with `arm64`; `arch -x86_64 uname -m` returned `x86_64`. No translated app launch was performed. |
| Evidence contains no private data | Pass | Only public source, synthetic tests, build metadata, and model-directory entry counts were inspected. No model output, user transcript, repository content, credentials, or customer data was recorded. |

Session summaries remain disabled by default. Native groundedness and memory acceptance remain blocked until the pinned model is installed and the checklist can run in a disposable ACP session with public or synthetic text.

## Automated verification

- `xcodegen`: exit 0, no tracked generated changes.
- `LocalTextModelManifest.json`: one resource build-file declaration and one Resources phase entry.
- Affected focused tests: exit 0, 193 tests in 15 suites.
- Debug arm64 build: exit 0.
- Release arm64 build: exit 0.
- Debug x86_64 build: exit 0.
- Release x86_64 build: exit 0.
