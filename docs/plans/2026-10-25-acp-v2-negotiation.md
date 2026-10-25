# ACP v2 negotiation foundation implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task.

**Goal:** Add the Debug preference and initialization foundation for ACP 1/2 coexistence while keeping live connections on ACP 1.

**Architecture:** Capture an immutable protocol selection when each connection is created. Decode the returned version before selecting a version-specific response schema. Keep v2 bootstrap data separate from the current v1 session capabilities.

**Tech stack:** Swift, Swift Testing, SwiftUI, the existing AlasCore modules.

**Spec:** [Umbrella issue #2213](https://github.com/mrmans0n/alas/issues/2213), workstream 1, narrowed by the approved conversation design below.

## Approved scope and approach

The first slice adds an off-by-default Experimental ACP 2 toggle to Settings > Debug, connection-scoped protocol selection, separate initialization schemas, and returned-version validation. Live v2 eligibility remains empty until the lifecycle and transcript work is implemented. The alternative, implementing a minimal live v2 session path in this slice, was declined in favor of the foundation.

The flag is persisted through AppConfig. The UI explains that no agents are enabled yet. Toggling it affects future connection selection only. Broker snapshot results are validated against the active supported version; no connection is restarted or reinitialized because of a settings change. An unexpected protocol version is an error, not a reason to retry a prompt or authentication.

## Global constraints

- Keep the v1 request shape and existing capabilities intact.
- Preserve Alas's identity; do not spoof AIR.
- V2 bootstrap parsing is not session compatibility. Production selection supports only v1 in this slice.
- Keep UI-free code in AlasCore. No new dependencies or project.yml changes.
- Extend focused test suites and use parameterized fixtures. No tests for view composition.
- Leave the prior research note intact and uncommitted.

## Review focus

- Unexpected versions must be rejected before optional v1 decoding hides their different shape.
- Disabled, missing, or malformed saved preferences must not activate a protocol.
- V1 selected in response to a v2 bootstrap must use the v1 response schema.
- Cached broker initialization must obey the same version validation as direct stdio.
- A saved flag must not mutate an already-created connection's immutable selection.

## Task 1: Bootstrap schemas and version validation

Files: `AlasACP/ACP/Protocol/{ACPProtocolVersion,ACPConnection}.swift`, a new `ACPInitialization.swift`, and package `ACPProtocolNegotiationTests.swift`.

Interfaces: versioned initialization parameters/results and immutable `ACPProtocolSelection`; the existing `ACPInitializeOutcome` continues to represent only the supported v1 session path.

- [x] Add a parameterized regression using ACPMockClient that rejects selected versions -1, 0, 2, and 3 after requesting 1. Observe its failure before implementation.
- [x] Add separate v2 bootstrap encoding/decoding, required identity checks, selected-version validation, and a typed unsupported-version error. Preserve optional and unknown bootstrap data without interpreting it as v1.
- [x] Cover v2 request shape, v1 downgrade decoding, v2 object support markers, unknown data, and malformed version/identity fixtures. Keep v2 parsing separate from runtime support.
- [x] Run `rtk swift test --package-path Packages/AlasCore --scratch-path /private/tmp/alas-acp2-core-build --filter ACPProtocolNegotiationTests` and check the real test count.

## Task 2: Persist and expose the gated preference

Files: `AlasModel/Persistence/AppConfig.swift`, `Alas/Sources/Settings/AdvancedPane.swift`, and existing package `AppConfigDecodingTests.swift`.

Interfaces: `AppConfig.experimentalACP2Enabled`, default false, and protocol selection initialized from that preference.

- [x] Add one meaningful config round-trip/legacy-input test for the preference and its resulting protocol selection; observe the missing implementation.
- [x] Persist the flag through the existing tolerant decoder. Add a compact toggle using SettingsGroup/SettingsRow/AlasToggle and existing state binding.
- [x] Explicitly explain that this foundational build has no v2-enabled agents. Adjust the Debug pane description to include experimental options.
- [x] Run the focused config and negotiation tests, then inspect the settings diff.

## Task 3: Capture selection at connection creation

Files: `AlasAgents/ACP/Session/ACPSessionManager.swift`, `AlasHostCore/Core/AlasCoreContext.swift`, and `Alas/Sources/App/AppState.swift`.

Interfaces: a current-preference provider on the manager, snapshotted into `ACPConnection.protocolSelection` for direct, broker, discovery, and remote connections.

- [x] Cover an existing connection retaining its selection while a subsequently created connection captures a changed preference. Validate both still send v1 in this stage.
- [x] Pass the current preference at each production connection construction point and from app/headless manager factories. Do not add an observer that mutates active connections.
- [x] Record selected protocol and adapter identity in existing diagnostics. Expose the negotiated version on the connection.
- [x] Cover a broker snapshot that selects an unsupported version without sending another initialize to the running agent.
- [x] Run affected AlasCore tests first, then a focused app build/test if available. Use isolated DerivedData and report infrastructure limits separately from test results.
- [x] Review the complete diff and perform one fresh-context review. Keep the change local; commit/PR creation is a separate request.

## Verification results

- The unsupported-version regression failed against the original connection implementation for all four selected versions, then passed after version-first decoding.
- The persisted opt-in round-trip regression failed before the config field was added, then passed.
- AlasCore: 49 tests in 4 suites passed using the focused filter `ACPProtocolNegotiationTests|AppConfigDecodingTests|ACPCodexHooksTests|ACPClaudeSessionHooksPolicyTests`.
- App: `ACPConnectionTests` and `ACPBrokerClientTests` passed, 86 tests and 145 executions including parameterized cases, with no failures or skips. The result bundle confirms `unsupportedAdoptedProtocolDoesNotReinitializeTheAgent()` passed.
- Independent read-only review found no actionable issues in the approved scope. `git diff --check` passed.
- App validation used isolated DerivedData and copied dependency checkouts. A generated Rust macro loader failure was repaired by rebuilding generated Rust artifacts under command-scoped Xcode 26.6; the successful app test run used Xcode 27.1 with four build jobs. No source changes were needed for the environment repair.
- No live v2 adapter session or manual settings walkthrough was performed. Live sessions remain v1 by design.
