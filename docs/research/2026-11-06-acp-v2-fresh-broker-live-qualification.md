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

A temporary Swift driver linked the built AlasCore library and used the real `JSONRPCStdioTransport`, `RemoteHelperClient`, `LocalACPBrokerService`, `ACPBrokerClient`, `ACPV2SessionRunner`, projection and SQLite persistence. Each invocation created an isolated scratch cwd, helper state directory, session and lease. Initialization used `info.name = "alas"`; no AIR identity or markers were supplied. The driver explicitly closed its broker and shut down its helper client.

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
| Explicit cleanup | Passed, broker list empty | Passed, broker list empty |

Codex first completed a text-only prompt and a harmless `printf` tool request. Neither required permission under its default mode, so those runs alone do not qualify permission replies. A separate invocation set the adapter's documented `INITIAL_AGENT_MODE=read-only` and requested a write only to `permission-probe.txt` in the disposable cwd. The runner cancelled the resulting `session/request_permission`. SQLite held exactly one intent, attempt and observation; the reply outcome was cancelled and the transport fact was `broker(.written)`. The final idle update carried `stopReason: cancelled`, the runner remained ready, and the file did not exist. The persisted ACK cursor reached 29 in this run. Codex's successful two-prompt run reached cursor 36.

The original Claude authentication failures were failed model runs, even though prompt acceptance and foreground completion events were observed. The follow-up below identifies a qualification-driver environment error and replaces the authentication blocker with successful live evidence. No sign-in, credential changes or fallback to ACP v1 were needed.

## Claude follow-up, 2026-11-07

The CLI reported an existing `claude.ai` login. Repeating `auth status --json` with only `HOME` and `PATH` reported logged out, while the explicit standard-variable allowlist `HOME`, `PATH`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG` reported logged in. The helper deliberately clears inherited adapter environment variables and launches with the supplied environment. The temporary driver had supplied only `PATH`, so its authentication result did not establish a missing user login. Adding only `HOME` was also insufficient. The corrected driver supplied the seven standard variables and the Codex-only `INITIAL_AGENT_MODE` selector. It did not forward credential environment variables; which individual standard variable is necessary was not isolated.

With that allowlist, Claude completed the text-only prompt with `ACP_V2_READY` and the harmless `printf` request with `ACP_V2_PERMISSION_CHECK`. SQLite recorded two submissions, two outcomes and two idle updates with `stopReason: end_turn`. The runner remained ready and the persisted ACK cursor reached 44.

For a separate permission run, the driver selected Claude's `default` mode through the installed adapter's `session/set_config_option` method, using `configId: mode`, `type: id`, and `value: default`. This affected only the disposable session. The driver requested a write to `permission-probe.txt` in that scratch cwd and cancelled the resulting `session/request_permission` through `runner.decide`. SQLite recorded one response intent, one attempt and one observation, with reply outcome `cancelled` and a transport receipt of `broker(.written)`. Claude returned `PERMISSION_CANCELLED`, then an idle `end_turn` update. Cancelling a permission did not cancel the whole foreground turn in this run. The file did not exist, the runner remained ready, and the persisted ACK reached 46. Both successful invocations explicitly closed the broker and confirmed an empty helper broker list.

The installed Claude version remained `0.101.0-alas.1`. Its executable SHA-256 was `a588a38be1121345a70345196476801c5a57cba5671812d51803dd2a91044cce`; the helper hash remained the one recorded above. This follow-up changed the temporary driver and this report only; it required no product code change.

## Startup defect found and fixed

Both real adapters initially failed fresh runner startup with `invalidAttachment`. SQLite showed an empty update stream with a nonzero initial broker cursor. Setup RPC completions and automatically consumed `operationStarted` controls could advance the durable broker mirror before the fresh owners registered. The fresh replay guard correctly refused the resulting apparent missing prefix.

Deferring only response consumption was insufficient: an earlier `operationStarted` control still advanced the ACK. The final fix holds the entire ACK prefix while an ordered fresh bootstrap claim is active. After initialize/new dispatch and both owners reaching ready, the same claim releases the barrier and flushes eligible ACKs. Failed or invalidated installation does not release it. Standalone intake and split-mode behavior are unchanged.

The regression `freshBrokerSetupConsumptionWaitsForBothJournals` uses no buffered methods, includes setup start controls, and forces the durable mirror to run before any subsequent registration. It failed before the barrier with missing journals and an invalidated runner, then passed with an initial journal cursor of zero and subsequent ACK advancement.

## Evidence and limits

Local evidence is under `/private/tmp/alas-v2-live-qualification/` and is temporary, not a committed fixture or CI artifact:

- `*-initialize.json`: exact direct initialize request/response and adapter executable hashes.
- `main.swift`, `compile.log`: temporary driver and link evidence.
- `*-startup-barrier.log`: real fresh startup, persisted binding and empty broker list after cleanup.
- `codex-acp-prompts.log`, `codex-acp-permission.log`, `claude-agent-acp-prompts.log`: original live prompt results, including the incomplete-environment Claude failures.
- `claude-agent-acp-standard-env-2026-11-07.log`, `claude-agent-acp-permission-2026-11-07.log`: successful authenticated Claude runs.
- `claude-verified-2026-11-07.json`: SQLite checks for submission/response counts, permission reply, terminal stop reasons, ACK cursor and absent scratch file.
- `setup-prefix-red.log`, `setup-controls-red.log`, `setup-controls-green.log`: regression evidence, including the insufficient response-only fix.
- `affected.log`: 109 tests in 6 suites passed. Selection: `ACPBrokerRawClientTests|ACPV2SessionBootstrapTests|ACPV2SessionRunnerTests|ACPV2AttachmentRuntimeTests|ACPBrokerTransportTests`.
- `lint.log`: all five edited Swift files passed SwiftFormat lint. Whitespace validation also passed.

Remaining gates include source provenance verification for the installed packages and any broader live replay/crash or production integration qualification. These results do not activate either adapter for production ACP v2.
