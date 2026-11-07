# Fresh ACP v2 broker live qualification, 2026-11-06

Updated 2026-11-07 after authenticated Claude prompt and permission checks.

This is a bounded local qualification of the opt-in package runner. Production remains on ACP v1. It does not qualify reattachment, process restart, session/resume, SSH, queues, outgoing cancellation, or production interaction UI.

## Components

- Alas source starts at `0424cc1c98a157b77f3cde5e555f7a18889c8faf`, with the bootstrap ACK barrier fix accompanying this report.
- Installed Codex adapter: `@alas-ide/codex-acp@2.5.0-alas.6`.
- Installed Claude adapter: `@alas-ide/claude-agent-acp@0.101.0-alas.1`.
- Real bundled macOS arm64 helper: `/Applications/Alas.app/Contents/Resources/alas-helper/macos-aarch64/alas-helper`. Hello reports binary version `0.10.0`, raw frame capability 1 and raw reply capability 1.
- Helper SHA-256: `f7769029f4e7f51ab1c3373f33ce6625964f93da05e68219c465994115a975ef`.

Package versions came from the installed manifests. The initialize probes also recorded executable hashes. No adapter update or publication was performed; package source-commit provenance was not independently established.

## Method

A temporary Swift driver linked the built AlasCore library and used the real `JSONRPCStdioTransport`, `RemoteHelperClient`, `LocalACPBrokerService`, `ACPBrokerClient`, `ACPV2SessionRunner`, projection and SQLite persistence. Each invocation created an isolated scratch cwd, helper state directory, session and lease. Initialization used `info.name = "alas"`; no AIR identity or markers were supplied. The driver requested broker closure and shut down its helper client; its original list call observed only the v1 namespace.

The initial long temporary path exceeded the macOS Unix socket path limit. Short `/private/tmp/q-<random>` roots resolved that harness issue. Subsequent failures described below used those valid paths.

## Results

| Behavior | Codex | Claude |
|---|---|---|
| Direct ACP v2 negotiation with Alas identity | Passed | Passed |
| Real helper open, initialize, session/new and runner ready | Passed after ACK fix | Passed after ACK fix |
| Fenced broker/session binding | Passed | Passed |
| Model prompt acceptance | Passed | Passed with corrected driver launch environment |
| Expected assistant text and successful foreground completion | Passed, `ACP_V2_READY` and `end_turn` | Passed, `ACP_V2_READY` and two `end_turn` completions |
| Permission cancellation through durable response owner | Passed | Passed, one cancellation reply written |
| Persisted broker ACK advancement | Observed | Observed for successful prompt and permission runs |
| Explicit cleanup | Close requested; raw list was not checked | Close requested; raw list was not checked |

Codex first completed a text-only prompt and a harmless `printf` tool request. Neither required permission under its default mode, so those runs alone do not qualify permission replies. A separate invocation set the adapter's documented `INITIAL_AGENT_MODE=read-only` and requested a write only to `permission-probe.txt` in the disposable cwd. The runner cancelled the resulting `session/request_permission`. SQLite held exactly one intent, attempt and observation; the reply outcome was cancelled and the transport fact was `broker(.written)`. The final idle update carried `stopReason: cancelled`, the runner remained ready, and the file did not exist. The persisted ACK cursor reached 29 in this run. Codex's successful two-prompt run reached cursor 36.

The original Claude authentication failures were failed model runs, even though prompt acceptance and foreground completion events were observed. The follow-up below identifies a qualification-driver environment error and replaces the authentication blocker with successful live evidence. No sign-in, credential changes or fallback to ACP v1 were needed.

## Claude follow-up, 2026-11-07

The CLI reported an existing `claude.ai` login. Repeating `auth status --json` with only `HOME` and `PATH` reported logged out, while the explicit standard-variable allowlist `HOME`, `PATH`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG` reported logged in. The helper deliberately clears inherited adapter environment variables and launches with the supplied environment. The temporary driver had supplied only `PATH`, so its authentication result did not establish a missing user login. Adding only `HOME` was also insufficient. The corrected driver supplied the seven standard variables and the Codex-only `INITIAL_AGENT_MODE` selector. It did not forward credential environment variables; which individual standard variable is necessary was not isolated.

With that allowlist, Claude completed the text-only prompt with `ACP_V2_READY` and the harmless `printf` request with `ACP_V2_PERMISSION_CHECK`. SQLite recorded two submissions, two outcomes and two idle updates with `stopReason: end_turn`. The runner remained ready and the persisted ACK cursor reached 44.

For a separate permission run, the driver selected Claude's `default` mode through the installed adapter's `session/set_config_option` method, using `configId: mode`, `type: id`, and `value: default`. This affected only the disposable session. The driver requested a write to `permission-probe.txt` in that scratch cwd and cancelled the resulting `session/request_permission` through `runner.decide`. SQLite recorded one response intent, one attempt and one observation, with reply outcome `cancelled` and a transport receipt of `broker(.written)`. Claude returned `PERMISSION_CANCELLED`, then an idle `end_turn` update. Cancelling a permission did not cancel the whole foreground turn in this run. The file did not exist, the runner remained ready, and the persisted ACK reached 46. Both successful invocations requested raw broker closure. The temporary driver queried the default v1 list afterward, so those outputs do not establish raw-v2 cleanup. The reusable qualification driver now queries raw-v2 and legacy namespaces explicitly.

The installed Claude version remained `0.101.0-alas.1`. Its executable SHA-256 was `a588a38be1121345a70345196476801c5a57cba5671812d51803dd2a91044cce`; the helper hash remained the one recorded above. This follow-up changed the temporary driver and this report only; it required no product code change.

## Startup defect found and fixed

Both real adapters initially failed fresh runner startup with `invalidAttachment`. SQLite showed an empty update stream with a nonzero initial broker cursor. Setup RPC completions and automatically consumed `operationStarted` controls could advance the durable broker mirror before the fresh owners registered. The fresh replay guard correctly refused the resulting apparent missing prefix.

Deferring only response consumption was insufficient: an earlier `operationStarted` control still advanced the ACK. The final fix holds the entire ACK prefix while an ordered fresh bootstrap claim is active. After initialize/new dispatch and both owners reaching ready, the same claim releases the barrier and flushes eligible ACKs. Failed or invalidated installation does not release it. Standalone intake and split-mode behavior are unchanged.

The regression `freshBrokerSetupConsumptionWaitsForBothJournals` uses no buffered methods, includes setup start controls, and forces the durable mirror to run before any subsequent registration. It failed before the barrier with missing journals and an invalidated runner, then passed with an initial journal cursor of zero and subsequent ACK advancement.

## Evidence and limits

Local evidence is under `/private/tmp/alas-v2-live-qualification/` and is temporary, not a committed fixture or CI artifact:

- `*-initialize.json`: exact direct initialize request/response and adapter executable hashes.
- `main.swift`, `compile.log`: temporary driver and link evidence.
- `*-startup-barrier.log`: real fresh startup, persisted binding and an empty legacy broker list after requesting closure; raw-v2 cleanup was not verified by that list.
- `codex-acp-prompts.log`, `codex-acp-permission.log`, `claude-agent-acp-prompts.log`: original live prompt results, including the incomplete-environment Claude failures.
- `claude-agent-acp-standard-env-2026-11-07.log`, `claude-agent-acp-permission-2026-11-07.log`: successful authenticated Claude runs.
- `claude-verified-2026-11-07.json`: SQLite checks for submission/response counts, permission reply, terminal stop reasons, ACK cursor and absent scratch file.
- `setup-prefix-red.log`, `setup-controls-red.log`, `setup-controls-green.log`: regression evidence, including the insufficient response-only fix.
- `affected.log`: 109 tests in 6 suites passed. Selection: `ACPBrokerRawClientTests|ACPV2SessionBootstrapTests|ACPV2SessionRunnerTests|ACPV2AttachmentRuntimeTests|ACPBrokerTransportTests`.
- `lint.log`: all five edited Swift files passed SwiftFormat lint. Whitespace validation also passed.

The source audit below closes the installed top-level package provenance gate. Positive one-time approval, full execution-closure identities and integrated Debug app qualification remain pending. These results do not activate either adapter for production ACP v2.

## Immutable source audit, 2026-11-07

Both installed top-level packages match every file in their exact npm tarball: 4 files for Codex and 312 for Claude. Tarball SHA-512 matches npm integrity. The npm Sigstore verifier validated each SLSA bundle against the GitHub Actions OIDC issuer and its exact fork `publish-alas.yml@refs/heads/alas` identity. Each signed subject matches the tarball digest and each signed resolved source commit matches the fork's release tag and `alasDownstream.sourceCommit`. Codex also publishes the same `gitHead`; Claude does not publish `gitHead`.

- Codex `2.5.0-alas.6`: [source 7c99c083270255f2960fa4cd2da93f72bdf402ad](https://github.com/mrmans0n/codex-acp/tree/7c99c083270255f2960fa4cd2da93f72bdf402ad), [provenance workflow](https://github.com/mrmans0n/codex-acp/actions/runs/42083581726/attempts/1).
- Claude `0.101.0-alas.1`: [source 863c0ac5b3d588a605185117f14338fb9f57f230](https://github.com/mrmans0n/claude-agent-acp/tree/863c0ac5b3d588a605185117f14338fb9f57f230), [provenance workflow](https://github.com/mrmans0n/claude-agent-acp/actions/runs/42154616176/attempts/1).

The immutable sources contain dual v1/v2 routers and v2 initialize/new/prompt implementations. This audit did not install, update or publish any adapter. Dependency execution bytes are a separate identity from the top-level npm tarball. The reusable tool hashes the entire installed package tree, including dependencies and native executables, and rejects links escaping that tree. Its evidence uses Alas client identity and records the requested default CLI login route; authenticated provider identity must be verified separately before a record can enter eligibility.

The machine-readable provenance audit and pending qualification gates are in `2026-11-07-acp-v2-preview-qualified-adapters.json`. Its `qualifiedAdapters` list now contains the two exact local launch identities verified below. This evidence does not enable app rollout.

The reusable-driver work found two probe defects before admission: URL identity retained a pre-creation file/directory hint and refused an actual matching scratch cwd; a failing regression now pins canonical path comparison. The temporary driver's context-free broker list also queried v1, so its earlier empty-list cleanup assertions are downgraded above. Fresh format-3 runs require one matching active raw-v2 source, a drained captured journal tail, and zero raw-v2 and v1 brokers after closure. Positive writes observed before these audit corrections remain partial evidence.

## Reusable driver qualification, 2026-11-07

All four final format-3 cases passed using the real local helper, package runner, canonical foreground completion and SQLite response ledger. Each run completed the exact `ACP_V2_READY` prompt first. Each permission case received one offer and persisted exactly one intent, attempt and broker-written observation. The driver checked the stored selected/cancelled reply, revalidated package/helper/Node content identity, and verified one matching active raw-v2 broker before closure and zero brokers in both namespaces afterward.

| Adapter and mode | Permission outcome | Foreground result | Sentinel | Captured tail / persisted ACK | Final raw / legacy brokers |
|---|---|---|---|---|---|
| Codex read-only, allow-once | Selected once, written | completed | Exact bytes | 69 / 69 | 0 / 0 |
| Codex read-only, cancel | Cancelled, written | cancelled | Absent | 52 / 52 | 0 / 0 |
| Claude default, allow-once | Selected once, written | completed | Exact bytes | 69 / 69 | 0 / 0 |
| Claude default, cancel | Cancelled, written | completed | Absent | 58 / 58 | 0 / 0 |

Claude's cancelled permission again ended the foreground turn normally; it did not report a cancelled foreground. The tool distinguishes these facts. The allowed command was a fixed `printf` writing only the sentinel file in a new private scratch directory. It never selected an `allow_always` option, used fallback approval, or forwarded credential environment variables. Raw request/model/account content is absent from the committed evidence. Private helper state and SQLite files were removed after verified cleanup.

The machine-readable record includes complete installed execution-tree digests, source/integrity proofs, helper and Node digests, provider and approval mode, plus the sanitized final case reports. Codex uses the standard OpenAI ChatGPT login route; Claude uses the standard first-party claude.ai route. Normal keychain access was needed to verify Claude CLI and bundled SDK authentication status. No sign-in or credential change was made.

The driver is a separate package under `Tools/ACP2Qualification`, outside the default app/core test plan. Its four tests cover seven closed permission-policy variants, cancellation, dependency-byte identity changes, escaping links, and the exact pre-creation directory-URL regression. They passed locally; the focused core baseline also passed 61 tests across 3 suites. No app build or integrated preview smoke test has run in this task.

Example invocation after building the tool:

```sh
rtk swift run --package-path Tools/ACP2Qualification acp2-qualify \
  --adapter /opt/homebrew/bin/codex-acp \
  --helper /Applications/Alas.app/Contents/Resources/alas-helper/macos-aarch64/alas-helper \
  --permission allow-once --output /private/tmp/acp2-qualification-result
```

Use a new output directory for each run. Repeat with `--permission cancel` and the verified Claude executable. The tool refuses to overwrite an existing `result.json`. Ordinary Alas sessions still use v1; production admission, app integration and manual Debug validation are later plan tasks.
