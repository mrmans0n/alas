# Codex hook trust verification for issue #2044

The published adapter and Alas integration were verified against source commit `564797465c8c60fa079ebb3c43b577c7b51451fa`. This note records the exact release, live and native results, reproducible procedure, and limits. It does not claim a real-provider smoke test, live SSH run, or green main-Alas CI.

## Negotiated contract

Alas keeps `clientInfo` identity `Alas` and opts in per initialization with `clientCapabilities._meta.codexHooks = {version: 1}`; this is not AIR mode. The adapter reports its own `@alas-ide/codex-acp` identity and `_meta.codexHooks = {version: 1, reviewToken: true}`. Swift negotiates after initialization only for the known managed package at the verified version floor. Custom binary overrides and unnegotiated clients, including existing AIR clients, retain prior behavior.

| Rule | Runtime behavior |
| --- | --- |
| Release floor | Only the managed package at or above `2.2.2-alas.4` may negotiate. |
| Discovery | `_codex/hooks/list {cwd}` is read-only and reports definitions, diagnostics, review token, and adapter-reported `codexHome`. |
| Consent | `_codex/hooks/trust` writes only explicitly selected exact key/hash pairs; Alas checks true result and fresh readback. False/error requires a new list. |
| Execution | Hook-capable thread, prompt, goal, and steering operations carry an ephemeral token bound to process and reviewed hook/provider state. Changes require review before dispatch. |
| Retry | Only `-32044` with `codex_hook_review_required` or `codex_hook_changed` permits whole-operation retry after review. `-32603` and recovery-wrapped `1001`/restartable errors do not. |
| Scope | Trust lives in shared `CODEX_HOME/config.toml` (also used by Codex CLI and other projects); changed commands replace the key's hash after review. SSH uses the remote host's home. |

Read-only discovery and deletion do not opt into execution review.

## Published artifact and CI

The reviewed downstream change merged as [fork PR #12](https://github.com/mrmans0n/codex-acp/pull/12). The exact published package is [`@alas-ide/codex-acp@2.2.2-alas.4`](https://www.npmjs.com/package/@alas-ide/codex-acp/v/2.2.2-alas.4), based on upstream `2.2.2` at `202e66e63343ec4f5a5e35ab590251d813d129ca`, with published source/gitHead `4b517e7e77ece05ef63f34c890bc853b7fb96a43`.

The [required CI run 39584966318](https://github.com/mrmans0n/codex-acp/actions/runs/39584966318) succeeded. The publication job in [release run 39585698241](https://github.com/mrmans0n/codex-acp/actions/runs/39585698241) recorded 1,717 unit tests passed and 36 skipped, then completed publication and provenance readback. The npm manifest's immutable tarball integrity is:

```text
sha512-rDd7j8RTJyuVYpW6xr5+0oHCDyId1NzLgPJeYxkUpjAZnyZr+lTOSASLL31ZO5We27fo1nrh1ISr1otNaZLQDw==
```

Verification covered source/tag, provenance, and the downloaded tarball's integrity before install; no local checkout build was used. The release workflow's real-provider E2E job was waived because its provider secret was unavailable.

The adapter's final broad local suite reported four failures: three 5-second sync-review timeouts reproduced on unchanged base, and one ledger invariant later corrected. Focused ledger checks passed after correction; the broad suite was not rerun. Required fork CI and release records above are the CI evidence.

## Exact published-package live proof

The exact tarball was installed under `/private/tmp/alas-2044-published-probe/install`; its entry SHA-256 was `14a5fa04db8cf6b73502da06fd6d7be9a2f51720cbe9bbe644c0009a451a7cfd`. The probe used Codex `0.160.1`, adapter PID `55040`, private home `/private/tmp/alas-2044-published-run-zPaXtm/codex-home`, and scratch workspace under the same root. It read/copied no real credentials or trust. Real Codex app-server and hooks ran against a deterministic loopback Responses fixture; auto-title turns were suppressed.

| Check | Observed result |
| --- | --- |
| Neutral initialize | Alas identity; adapter identity/version and `{version:1, reviewToken:true}` returned; no AIR marker. |
| Read-only list | Two untrusted SessionStart hooks and scratch home returned; config and markers unchanged. |
| Untrusted first prompt | Real turn completed; neither hook ran and config stayed unchanged. |
| Explicit selected trust | Exact first key/hash returned trusted and was persisted; second hook remained untrusted. |
| Trusted first prompt | Thread creation ran no hook; the first prompt's SessionStart marker matched session `01a15e0d-7b6b-70c1-a3c2-d30d6a974011`. |
| Stale hash | `-32044 / codex_hook_changed`; no config, marker, or model effect. |
| App-server replacement | Old token returned `-32044 / codex_hook_review_required` before a model request. |
| App-server revalidation | Adapter PID stayed `55040`; native PID `55086 → 55601`. Fresh token resumed the session with the selected hash preserved. |
| Provider replacement | `providers/set` changed native PID `55601 → 55699`; old token was rejected before provider/marker effects. |
| Provider revalidation | Fresh token resumed successfully; selected hash remained trusted and unselected hook never ran. |

Four Responses requests reached the fixture: untrusted, trusted, post-app-server replacement, and post-provider replacement turns. Rejected requests added none. All ten recorded checks passed; process exit was zero.

The probe's actual persistent trust entry was:

```toml
[hooks.state."/<session-flags>/config.toml:session_start:0:0"]
trusted_hash = "sha256:6104c246dab97998822e850749dfb847181690555065b6643d2838cba2b74dc6"
```

The second key, `/<session-flags>/config.toml:session_start:0:1`, remained untrusted and absent. This is shared Codex-home trust, isolated here to the scratch home.

### Reproduction outline

The temporary harness is local provenance, not a shipped test artifact. To reproduce:

1. Create a mode-`0700` temporary root with private `CODEX_HOME`, workspace, and install directory. Install with `npm install --prefix "$TMP/install" --ignore-scripts --no-audit --no-fund @alas-ide/codex-acp@2.2.2-alas.4` and compare the downloaded tarball SRI with the manifest value above.
2. Add two harmless SessionStart commands that append only event, session ID, and cwd to distinct temporary marker files. Copy no existing config or credentials.
3. Start the installed adapter with that home and a deterministic loopback Responses endpoint. Initialize as Alas with `clientCapabilities._meta.codexHooks = {version:1}`, verify adapter identity/capability, then call `_codex/hooks/list` with `{cwd}`.
4. Prompt without trust and confirm no marker/config change. Call `_codex/hooks/trust` with `{cwd,reviewToken,hooks:[{key,currentHash}]}` containing one displayed pair; verify true and readback. Send the review token as `_meta.codexHooks.reviewToken` on new/prompt requests. Thread creation should not run a marker; the first prompt should run only the selected hook.
5. Submit a stale hash and confirm `-32044 / codex_hook_changed`. Kill only this adapter's native Codex descendant, trigger supervised replacement, and confirm the old token gets `-32044 / codex_hook_review_required`; list again and resume with the fresh token.
6. Change provider with `providers/set`; confirm the old token is rejected before provider execution, then list and resume with the fresh token. Confirm the unselected marker and hash remain absent.

The original probe source and machine evidence are `/private/tmp/alas-2044-published-probe/probe.mjs` and `/private/tmp/alas-2044-published-run-zPaXtm/evidence.json`. These local paths document provenance; they are not portable artifacts or CI evidence.

## Native Alas review flow

The manual check used a disposable uniquely identified app copy and scratch home under `/private/tmp/alas-2044-manual-ui-zdk3wwzi`; product sources and everyday profile were unchanged.

Baseline review showed hook scope/details, untrusted state, empty selection, and disabled Trust selected. Refresh was read-only; continue-without-trust opened a session without config or marker changes. A separate chat cancelled without trust. A scratch-home write failure left review visible, config bytes unchanged, and no marker; retry after restoring permissions trusted only the selected hook.

The native selected key was `/<session-flags>/config.toml:session_start:0:0`, with fixture hash `sha256:8a9fe322bf4a49e5beff7b397ed86d1b6a2015567dc7be1f9bb3e7b708195dbc`. Two selected markers were observed: one for the main session and one for the adapter's ephemeral automatic-title session on the same guarded app-server. This is not two main-session first prompts; the unselected hook never ran.

After changing the first command and restarting with the same scratch trust home, Alas showed a modified hash `sha256:66f28734fbcdd008674a2f6b12d1e165fba4a4bb710a0bdcbb5429e862e79dcb`, empty selection, and disabled trust. The 1,176-character command remained untrusted; continuing without trust changed no config or marker.

After the review presentation repair, Details showed the entire long command as selectable wrapped text. Parent continuation without trust restored the top-docked `/btw` card; the child showed its own modified/untrusted scope with empty selection and continued without trust. A fresh `hooks={}` startup completed automatically and kept the card visible. No extra trust was granted; config was unchanged, selected marker count stayed two, unselected stayed zero. No live SSH endpoint was available.

## Alas validation and limits

The final integrated source commit is `564797465c8c60fa079ebb3c43b577c7b51451fa` (`fix(acp): preserve success after delayed review rejection`). Final checks recorded for that source were:

| Area | Command | Result |
| --- | --- | --- |
| Core | `rtk swift test --package-path Packages/AlasCore --scratch-path /private/tmp/alas-2044-core-build --jobs 4` | 277 test definitions in 42 suites passed. Log: `/private/tmp/alas-2044-final-fix-package.log`. |
| App | `rtk proxy xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/alas-2044-derived-data -resultBundlePath /private/tmp/alas-2044-final-fix-app.xcresult -skipPackagePluginValidation -skipMacroValidation -only-testing:AlasTests/ACPConnectionTests -only-testing:AlasTests/ACPBrokerClientTests -only-testing:AlasTests/ACPSessionManagerTests -only-testing:AlasTests/ACPSessionRunnerQueueTests -only-testing:AlasTests/RemoteHelperClientTests -jobs 4 -quiet test` | Passed: 316 definitions, 458 executions, zero failures or skips. Result bundle: `/private/tmp/alas-2044-final-fix-app.xcresult`. |
| Helper protocol | `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer cargo test --manifest-path AlasHelper/Cargo.toml --target-dir /private/tmp/alas-2044-helper-tests --test acp_broker_protocol` | 23 protocol tests passed. No helper source changed in the final repair. |
| Helper process handler | `DEVELOPER_DIR=/Applications/Xcode-26.6.0.app/Contents/Developer cargo test --manifest-path AlasHelper/Cargo.toml --target-dir /private/tmp/alas-2044-helper-tests reviewed_operation_replay_preserves_success_and_delivers_rejection_before_eviction` | 1 process-handler test passed. No helper source changed in the final repair. |

One earlier frozen full core run reported `.notWriter` in `HostSessionsTests.archivingJustAfterCreatingSticks`. Its exact isolated rerun and unchanged full rerun passed, followed by the final 277/42 run. The cause of that intermittent failure was not established and no archive/lease code was changed. The focused core log `/private/tmp/alas-2044-task3-fix1-cancel-green.log:5-12` records an `ImplicitStrongCapture` warning at `ACPSessionManager.swift:7349`. The identical closure exists at base `3b2f93831` lines 7250–7265; the warning predates these changes. These results do not claim repository-wide Alas CI is green.
