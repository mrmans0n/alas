# Editor LSP verification

Date: 2026-09-14. Scoped verification is complete with the limitations below. The full application suite is not green, and unavailable live checks prevent a claim of full acceptance.

## Scope

The final-verification changes add scoped CI coverage, repair a test source matcher, exercise a mounted inlay edit through preview/application/undo, measure native input with a delayed server, and collect opt-in live-server evidence. A real Rust shutdown exposed replies sent after exit and a SIGPIPE crash. A narrow fix guards the client write boundary and configures only the LSP transport's stdin descriptor to turn a closed pipe into a thrown error. Workspace-edit validation and other transports are unchanged.

The mounted inlay test uses the production coordinator, its unmodified inlay action callback, CodeActionsFeature, native preview model, file access, journal, and operation undo. It confirms that hint text stays out of source and disk, open edits remain unsaved, undo/redo spans the operation, stale hint IDs fail, and a changed source invalidates an open preview. It invokes AppKit and hosted action entry points in process; it is not physical mouse, VoiceOver, or IME automation.

## Reproduction

Run from this checkout. Preserve old bundles and choose a new result path for each attempt.

```sh
rtk xcodegen
rtk swiftformat AlasTests/Code/LSP/LSPTransportTests.swift \
  AlasTests/Code/LSP/LSPServerRequestsTests.swift \
  AlasTests/Code/LSP/EditorDisplayIntegrationTests.swift \
  AlasTests/Code/LSP/LiveLanguageServerVerificationTests.swift \
  Alas/Sources/Code/LSP/LSPClient.swift \
  Alas/Sources/Code/LSP/LSPTransport.swift --cache ignore
rtk xcodebuild -project Alas.xcodeproj -scheme Alas \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-recovery-dd \
  -quiet build build-for-testing
git diff --check
```

The three new steps in `.github/workflows/build.yml` contain the complete CI selector lists. Local verification uses those same selectors and `test-without-building`, an arm64 destination, serial testing, and 60-second per-test limits. CI keeps its `.build/xcode` package/build caches and eight-minute step limits. No intentionally excluded subprocess-heavy legacy suites were enabled.

The opt-in live collector is excluded from ordinary CI execution by a Swift Testing condition. Select one installed server and provide an output JSON path:

```sh
TEST_RUNNER_ALAS_LSP_VERIFY=1 \
TEST_RUNNER_ALAS_LSP_VERIFY_LANGUAGE=swift \
TEST_RUNNER_ALAS_LSP_VERIFY_EXECUTABLE=/Applications/Xcode-26.4.1.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp \
TEST_RUNNER_ALAS_LSP_VERIFY_OUTPUT=/private/tmp/alas-live-swift-new.json \
TEST_RUNNER_PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin \
rtk xcodebuild -project Alas.xcodeproj -scheme Alas \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-recovery-dd \
  -resultBundlePath /private/tmp/alas-live-swift-new.xcresult \
  -only-testing:AlasTests/LiveLanguageServerVerificationTests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 180 test-without-building
```

Xcode passes `TEST_RUNNER_` variables to the test host without that prefix. The collector makes its own disposable project below `.build/live-lsp-verification/<language>-<UUID>`, verifies its path has no alias, records the exact path in JSON, then removes only that UUID directory. It records raw server messages and per-method outcomes. A completed collector test means collection completed; empty responses, unsupported features, and failed requests remain separate in the report.

## Known limitations

- No live SSH fixture or remote disconnect drill was authorized. Deterministic remote file-access/recovery tests do not establish live SSH parity.
- Real VoiceOver and physical input-method composition remain unrun. Hosted accessibility and marked-text regression calls cover the application boundary only.
- The installed TypeScript executable is crates.io `typescript-language-server` 0.1.0, not the npm TypeScript language server. Standard npm server and `tsserver` are absent. No tools were installed.
- SourceKit returned both aliased `/var` and canonical `/private/var` document URIs in the first temporary fixture. Existing `/private/tmp` paths also standardize to `/tmp` in Foundation. The workspace-edit guard still refuses those mismatched identities before mutation. The product message now explains that targets must use the worktree's exact canonical path spelling and that `/tmp` versus `/private/tmp` aliases are unsupported. The collector's ordinary worktree path does not establish alias support.
- Navigation snippets now share one worktree-owned loader between references and the definition picker. Limits are four active document reads, 64 pending unique documents, 64 cached snapshots, 1 MiB per local/remote source and 8 MiB retained source bytes. Local IO runs off-main with a capped read; remote IO uses the existing bounded prefix API. Oversized/unreadable results remain navigable with “Snippet unavailable”. Dirty open source is authoritative; the bounded snapshot currently refuses open buffers longer than 262,144 UTF-16 units, lines beyond the first 65,536 indexed lines, and snippets longer than 512 UTF-16 units. These are snippet-only limits, not file-open limits.
- The previous completed full suite at `c3745c7d`, `/private/tmp/alas-task4-full.xcresult`, failed with 9,915 passing, 82 failing and 19 skipped logical tests. Only the two transport matcher failures and three stale ChatPane/Shortcut expectations have the narrow causal evidence described in the task report. The remaining failures are not all proven baseline failures.

Completed checks and the full-suite result are recorded below.

## Shutdown regression evidence

The Rust wire journal showed a normal manager-owned document close followed by shutdown request/result, a semantic refresh request, exit, an inlay refresh request, then the semantic refresh response and SIGPIPE. Deterministic regressions reproduced a real server closing stdin, newly received requests after dead state, and a configuration response which started while live but resumed after shutdown. Before the fix the first crashed with SIGPIPE, and the latter two wrote three and one extra responses respectively.

The focused GREEN bundle `/private/tmp/alas-task15-shutdown-green.xcresult` passed all 29 logical/device tests with zero failures/skips, exit 0. The client now rejects dead-state writes at the actual actor-isolated write boundary. On exit/end-of-stream it marks the client dead before cancelling inbound work. `LSPTransport.start()` checks `F_SETNOSIGPIPE` configuration on its own stdin descriptor and throws if configuration fails; subsequent `FileHandle.write` errors still propagate. No process-wide signal handler or signal mask changed.

## Installed-server results

These are application client/manager and workspace-executor checks, not mounted live-server UI checks. SourceKit is `/Applications/Xcode-26.4.1.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp`, Xcode 26.4.1 build 17E202, Swift 6.3.1. Rust analyzer is `/opt/homebrew/bin/rust-analyzer`, version `0.0.0 (9074e9b4c6 2026-09-06)`. TypeScript is `/Users/nacho/.cargo/bin/typescript-language-server`, crates.io package 0.1.0.

All three final collectors exited 0 with one logical/device test passed each. Raw initialize capabilities, responses, errors, and elapsed times are in `/private/tmp/alas-task15-live-{swift,rust,typescript}-closedbytes.json`; matching `.xcresult` bundles preserve the tests. Zero is an exercised-empty response, not unsupported. A passing collector means evidence collection finished, not that every capability succeeded. Diagnostic counts sum entries across received notifications, not unique diagnostics.

| Capability or operation | SourceKit | Rust analyzer | crates.io TypeScript |
| --- | --- | --- | --- |
| Initialize | Ready | Ready | Ready |
| Hover | Result | Failed, -32801 content modified | Result |
| Definition | 1 location | 1 location | 1 location |
| References | 3 locations | 3 locations | 2 locations |
| Type definition | Unsupported | Empty | Unsupported |
| Implementation | Empty | Empty | Unsupported |
| Quick fixes | Empty | Empty | 5 actions |
| Refactors | Empty | 5 actions | 5 actions |
| Formatting | Empty edit list | 4 edits | Unsupported |
| Completion | 30 items, 7 snippets, 0 imports | 118 items, 16 snippets, 0 imports | 71 items, 17 snippets, 0 imports |
| Signature help | 1 signature | 1 signature | 1 signature |
| Semantic tokens | 75 integers | 40 integers | 80 integers |
| Inlay hints | 1 hint | Empty | Empty |
| Prepare rename | Result | Result | Result |
| Rename application | 2 documents, preview, apply/undo/redo | 2 documents, preview, apply/undo/redo | 1 document, apply/undo/redo |
| External closed-file edit during preview | Rejected without partial application | Unrun for versioned second edit | Unrun, no cross-file edit returned |
| Diagnostics after invalid source | 5 published diagnostics | 1 published diagnostic | None observed within 2 seconds |
| Manager-owned close | Completed without crash | Completed without crash | Completed without crash |

Swift and Rust rename use the real manager's captured version 2 and preserve unsaved open text while mutating a closed file. The collector compares the complete expected closed-file bytes after apply and redo, and original bytes after undo. Workspace undo runs through TabsManager without a mounted text view. This does not establish live navigation-away/history behavior. Returned actions, formatting edits, completion snippets/imports, and semantic tokens were collected, not accepted or rendered through a mounted live editor. Their application/presentation paths have deterministic regression coverage in the scoped CI batches. TypeScript cross-file rename and live import completion were not established. No retry hides Rust's failed hover request.

## Scoped regression and responsiveness results

Final CI-equivalent batches completed exit 0 with zero failures/skips. Each selected suite had nonzero tests in its result tree.

| Bundle under `/private/tmp` | Logical tests | Device cases | Nonempty suites |
| --- | ---: | ---: | ---: |
| `alas-task15-ci-protocol-finalcode.xcresult` | 60 | 64 | 12 |
| `alas-task15-ci-workspace-finalcode.xcresult` | 80 | 91 | 7 |
| `alas-task15-ci-editor-finalcode.xcresult` | 214 | 268 | 21 |
| Total | 354 | 423 | 40 |

That historical editor batch includes 18 logical/24 device EditorDisplayIntegrationTests, including the mounted inlay action and source-only preview/undo checks. A 140,000-byte, 140,000-UTF-16-unit, 10,000-line fixture was tested while a fake hover reply waited two seconds. Native typing and menu construction finished in 0.04369375 seconds before that reply. Twenty distinct snippet requests completed in 0.079109959 seconds and returned the expected lines. This checks responsiveness for that fixture, not a general latency guarantee. At that source revision, up to 2.8 MB of whole-file input was read and the navigation cache had no eviction. The final-review pass replaces that loader; these old timings are not measurements of the new implementation.

The historical logs are not pristine. Main Thread Checker reported a CompletionFeatureTests callback reading NSTextView.string on the LSPClient actor's executor. The final-review pass moves that callback's AppKit reads and mutable observations to MainActor. The old stack was test code, not evidence of a production UI-thread violation.

`alas-task15-commit-publish.xcresult` separately passed all 24 logical/device tests with serial execution and 60-second limits. The older skipped-push stall did not reproduce in isolation; its root cause remains unproven.

## Full suite and provenance

Implementation commit: `e56d714df73a1dcf2fa5c2b5be8ed07eaac283b3`, `fix: guard LSP shutdown writes and verify editor workflows`. Post-commit hashes reproduce the verified source fingerprints below. The documentation commit changes no build inputs.

`/private/tmp/alas-task15-full.xcresult` finished with exit 65 in 1044.835 seconds. Of 10,023 logical tests, 9,924 passed, 79 failed and 20 were skipped. Device counts were 10,161 passed, 79 failed and 20 skipped. Exact failures are preserved in `/private/tmp/alas-task15-full-summary.json` and the bundle.

```sh
rtk xcodebuild -project Alas.xcodeproj -scheme Alas \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/alas-code-editor-lsp-recovery-dd \
  -resultBundlePath /private/tmp/alas-task15-full.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 test
```

All 79 failing IDs also appeared in the previous 82-failure run, with no new failing IDs. The two repaired ProcessTransportTerminationTests now pass. One unrelated scheduled-mirror test also passed this time; no causal fix is claimed. The three ChatPane/Shortcut stale expectations are proven baseline failures. The other failures are not collectively proven baseline or environmental.

The skipped-push test and `RightPaneGGStackTests/postMutationStackRefreshIsCancelledByReplacementRefresh()` each exceeded the configured 60-second allowance. Xcode recovered automatically and continued. The former still passes in its isolated suite. No unrelated subprocess or test repair was included.

The full run used the final production and ordinary-test changes based on `29d8ce43a89176316bf1d04b8eabcf14bbdde867`. The opt-in live test was skipped. After that run, six assertion-only lines tightened closed-file checks in the opt-in collector, followed by successful build-for-testing and the three final live runs. The controller explicitly accepted this verification split without another ordinary full run. The source-change fingerprint excluding that opt-in file stayed `b02ab0a3e50c694aa06d7294b638ccf44fd2ac5d4627ef05abf63e0a11b0cd7b`; its own SHA-256 changed from `a298d307168af81813a008538df7b9187c3d859af8cef0c0cd18c0e30cb094cb` to `280a0739586adebf46d6484b11f3a3a6786903cfaf1cc14f72ba19212eb8097a`.

The successful fixtures were removed by their owned cleanup. One older crash-left directory remains at `.build/live-lsp-verification/rust-BC154B49-307C-4BC4-9C48-10BDED40E6E8`; it predates incremental tracing and lacks matching saved path evidence, so it was retained under the cleanup ruling. Logs and result bundles were preserved.

## Final-review fix verification

This pass starts from `79a8ff151d1133368617b455977e1e52d0e3e52b`; implementation commit is `dfaaebde` (`fix: close editor LSP lifecycle and recovery gaps`). Source and ordinary tests are verified together; their diff SHA-256 against that base, including the CI workflow, is `f754a8404cf6957f8f629e767197dd1c5a5c701235af618977c8a7d04be6c23f`, unchanged after commit. The earlier installed-server collectors above were not rerun and are not evidence for these later source changes.

The pass adds immediate source-generation and mounted-binding validation, originating-holder requests for read-only external tabs, completion command sessions with real inbound applyEdit preview, whole-plan resource ownership preflight, and worktree-owned visible Undo/recovery. Successful history retires after its last live marker owner disappears; incomplete recovery remains. An unchanged initiating editor can own Undo for closed-file-only edits without becoming dirty or being reported as a changed document. Multiple pending recoveries remain visible, with exact-ID confirmation. View detach differs from final buffer closure, and another live participant permits checked clean-buffer reattachment.

Navigation retains its original reference query across caret/tab changes, rejects stale anchors, scopes clicked targets to menu actions, and exposes selected-result keyboard controls. References and definition pickers share bounded asynchronous snippets with dirty-source authority. Mounted delayed/empty/error/cancellation tests cover immediate feedback. A mounted picker regression also exposed recursive native accessibility fallback in unbound editor views; forwarding that legacy fallback directly fixes it without changing bound source/hint accessibility.

`xcodegen`, SwiftFormat lint (0/36 files requiring formatting), and `git diff --check` passed. App `build build-for-testing` passed in `/private/tmp/alas-final-fix-build-20260914c.xcresult`. Earlier compile-only and RED attempts remain in the local final-fix report and their untouched result bundles; no zero-test attempt is counted as passing tests.

The exact current CI selector batches passed on the final source, with zero failures/skips and no empty suites. `HoverFeatureBehaviorTests` is now included in the editor batch so the source-to-hint dwell regression runs in CI.

| Bundle under `/private/tmp` | Logical tests | Device cases | Nonempty suites |
| --- | ---: | ---: | ---: |
| `alas-final-fix-ci-protocol-20260914b.xcresult` | 60 | 64 | 12 |
| `alas-final-fix-ci-workspace-20260914b.xcresult` | 92 | 108 | 7 |
| `alas-final-fix-ci-editor-20260914b.xcresult` | 241 | 304 | 22 |
| Total | 393 | 476 | 41 |

Complete command output uses each bundle's stem with `.log` instead of `.xcresult`. Runs use `rtk proxy xcodebuild`, arm64 macOS, the isolated recovery DerivedData directory above, serial execution, and 60-second per-test limits.

The fresh full application suite `/private/tmp/alas-final-fix-full-20260914a.xcresult` finished exit 65 in 1069.961 seconds: **10,025 passed, 80 failed, 20 skipped** logical tests (10,125 total); device counts were 10,277 passed, 80 failed, 20 skipped. Full summary: `/private/tmp/alas-final-fix-full-20260914a-summary.json`. Source remained frozen at the fingerprint above throughout all final batches and the full run.

Exact `testIdentifierString` comparison with `/private/tmp/alas-task15-full-summary.json` shows all 79 earlier failing IDs recur, with one additional failure: `AppStateCleanupTests/deleteWorktreeCleansAppStateBeforeLaunchingFileCleanup()`. The three previously proven ChatPane/Shortcut baseline failures remain in that set; the other 76 recurring failures are previously observed, not collectively proven baseline or environmental. No editor/LSP CI-selected suite failed in the full run.

The additional cleanup case passed **5/5 isolated repetitions**, unchanged source, in `/private/tmp/alas-final-fix-cleanup-isolation-20260914a.xcresult` (one logical test, five cases, exit 0). Its full-run assertion expected the deleted worktree to be absent from the project list. The test waits for `operationState == nil`, while `performDeleteWorktree` clears that state before awaiting `refreshProjectWorktrees`; both that ordering and the test are unchanged at fix base `79a8ff15`. This suggests a pre-existing completion-barrier race, but does not prove a baseline failure or establish a definitive cause. It remains a newly observed full-run concern, not a confirmed regression introduced by these fixes. No unrelated lifecycle changes were made to force it green.

As in the earlier broad run, `RightPaneGGStackTests/postMutationStackRefreshIsCancelledByReplacementRefresh()` and `CommitPublishLiveOperationsTests/skippedPushMaterializesRemoteTrackingRefForUntrackedBranch()` exceeded the one-minute test allowance. Xcode restarted its test host and completed the run. Swift 6 concurrency migration warnings and always-run build-script notices remain; the final scoped logs contain no Main Thread Checker/UI-API alert. This is not a claim of manual accessibility/input verification or warning-free builds.

Only the three requested tracked scratch reports were removed from publication. Byte-identical ignored backups remain beside the local final-fix report. No other reports, old fixtures, ledgers, result bundles, or caches were deleted. Canonical-alias refusal and all live SSH/physical IME/manual VoiceOver limitations remain as described above.
