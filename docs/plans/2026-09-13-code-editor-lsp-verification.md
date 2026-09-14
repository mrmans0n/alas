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
- SourceKit returned both aliased `/var` and canonical `/private/var` document URIs in the first temporary fixture. Existing `/private/tmp` paths also standardize to `/tmp` in Foundation. The workspace-edit guard rejected those mismatched identities before mutation. The final collector uses an ordinary worktree path; support for aliases is not established by that run.
- `EditorNavigationStore.swift:5` caps concurrent snippet tasks at four, but lines 161 and 171 read whole files. `DefinitionSnippetCache.swift:33-41` splits the supplied whole text and the navigation cache has no entry eviction. Read bytes and retained navigation results are not bounded by the concurrent-task limit. Large-file measurements below must not be generalized into a bounded-memory claim.
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

The editor batch includes 18 logical/24 device EditorDisplayIntegrationTests, including the mounted inlay action and source-only preview/undo checks. A 140,000-byte, 140,000-UTF-16-unit, 10,000-line fixture was tested while a fake hover reply waited two seconds. Native typing and menu construction finished in 0.04369375 seconds before that reply. Twenty distinct snippet requests completed in 0.079109959 seconds and returned the expected lines. This checks responsiveness for that fixture, not a general latency guarantee. Four concurrent reads are allowed; up to 2.8 MB of whole-file input is read across those uncached targets. The retained navigation cache has no eviction, so the design's bounded-work acceptance remains a final-review concern.

The logs are not pristine. Main Thread Checker reports an existing CompletionFeatureTests callback reading NSTextView.string on the LSPClient actor's executor. The stack points to FakeTransport.onSend test code; this run does not establish a production UI-thread violation.

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
