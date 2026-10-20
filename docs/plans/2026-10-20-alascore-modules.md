# Splitting AlasCore into modules

## Why

The nightly's universal Release build takes over 100 minutes, and each
per-architecture release leg 31 to 57. Almost all of it is Swift compilation,
and most of that is one module: `AlasCore`, about 216,000 lines in 700 files.

A Release build compiles each module as a single whole-module optimization
(WMO) task per architecture. Measured locally for one architecture:

| Mode | Wall | CPU | Peak memory of one compiler |
|---|---|---|---|
| WMO (today) | 333 s | 526 s, mostly one core | 3.7 GB |
| Per-file batches | 238 s | 1,237 s across cores | 1.7 GB |

A GitHub macOS arm64 runner has 3 cores and 7 GB. The nightly compiles AlasCore
for both architectures at once beside MLX's C++, so two 3.7 GB compilers swap,
and each takes about 38 minutes instead of 5. The release legs compile package
targets for both architectures too, because forcing `ARCHS` also forces the
host-only macro tools (#1724).

Smaller modules lower each compiler's peak memory and let independent modules
compile in parallel, while keeping WMO, so the runtime code is optimized as
today. They also cut incremental builds: an edit recompiles one module.

## Goal

AlasCore becomes a set of SwiftPM targets in `Packages/AlasCore` that form an
acyclic graph, none larger than about a third of today's, with the existing
`AlasCore` product kept as an umbrella that re-exports them, so the app and the
tests import `AlasCore` unchanged. *Exit:* the nightly's build step takes under
60 minutes on the standard runner, and no single compiler exceeds 2 GB.

## Non-goals

- Changing behavior, public API shape or the app's imports.
- Splitting the app target.
- Linux portability (the module boundaries help it, but it is a separate plan).

## Where the cycles are

Today's folders depend on each other in cycles: ACP uses almost every folder and
almost every folder uses ACP. Against the layering below, 104 top-level types
are referenced from a lower layer. They fall into five groups, none of which
needs a redesign; each is a type or file in the wrong folder:

1. **Wire and value types under the feature that first needed them.** The
   JSON-RPC envelope, `ACPLaunchSpec`, `ACPMCPServer`, `ACPSetupCheck` and the
   broker messages live under `ACP/`, but SSH's helper protocol carries them.
   The `RemotePluginProc*` messages live under `Plugins/` and are SSH's too.
   `RemoteWorktreeFileAccess` and `RemoteFileNode` live under `Remote/` and are
   used by Git and ACP.
2. **The local text model** (`LocalText*`, `AppleGenerator`) lives under `ACP/`,
   but Issues, Attention and Projects use it.
3. **`AppConfig` aggregates every feature's settings types** (`LanguageServerConfig`,
   the GG modes, `ProjectShepherdSettings`, `ACPSideQuestionDockPreferences`,
   workspace and agent settings), so the file defining it depends on the
   features that define them, while those features read `AppConfig`.
4. **Host extensions in feature folders.** `AlasCoreContext` and `AlasHost`
   are extended from `Center/`, `ACP/` and `Shepherd/` (reviews, sessions,
   review status), and ACP refers back to `SessionsAPI` and `SessionRefusal`.
5. **A few genuine upward calls,** for example `Diagnostics` reading
   `ACPSessionManager`, or Git asking Checkpoints for `LiveCheckpointGitRunner`;
   each needs a protocol or a closure seam, as the package already does for the
   app (`PlatformServices`).

## Target modules

Bottom to top; each depends only on the ones before it.

| Module | From today's folders | Size |
|---|---|---|
| `AlasFoundation` | Helpers, SQLiteKit, JSONRPC, Watch, Dialogs, Diagnostics (minus the ACP reads) | ~2k |
| `AlasModel` | `AppConfig` and every settings type it holds, `Paths`/`AlasProfile`, `PersistenceStore`, ACP launch and MCP specs, the helper wire types, `SessionOwnerID`, `Worktree`/`WorktreeRef` and other shared value types | ~15k |
| `AlasPlatform` | SSH, Git, Search, RepoHooks, Zmx, Updates, LocalText | ~30k |
| `AlasFeatures` | Integrations, Issues, Center, Shepherd, Checkpoints, Projects, Workspace, RunScripts, Schedules, Attention | ~60k |
| `AlasCode` | Code (LSP, symbols, highlighting) | ~12k |
| `AlasAgents` | ACP (minus what moved down), Agents, Harness, Plugins, FailureBriefs, Right | ~75k |
| `AlasHostCore` | Core, Remote, the host extensions from feature folders | ~22k |
| `AlasCore` | Umbrella: `@_exported import` of all of the above | — |

`AlasAgents` is still about a third of today's module. If it alone stays over
the 2 GB budget, Phase 4 splits it along `ACP/Session` and `ACP/Adapter`, which
the same analysis can check.

Cross-module references use the `package` access level, which keeps them out
of the public API the app sees; anything the app uses is already `public`.
Tests are the exception the umbrella cannot cover: `@testable import AlasCore`
does not reach the internals of the modules it re-exports, and `package` only
reaches test targets inside the package. A test that uses an internal
declaration, as `ACPSessionRunnerTests` uses `remoteFileWriteForTesting`, adds
`@testable import` of the module that defines it; package targets are built
with testing enabled in Debug, as `AlasCore` is today. The
`@_spi(AppHost)` and `@_spi(Testing)` symbols (in 18 files) keep their SPI
names, which work across modules.

## Plan

Each phase is one or more PRs that build and pass on their own.

0. **A layering check.** `scripts/check-alascore-layers.py` maps each folder to
   its target module and fails on a reference from a lower module to a higher
   one, with the type and file. It runs in CI beside the other script tests,
   first reporting the 104 known violations as an allowlist that may only
   shrink, so new ones cannot appear while the moves land.
1. **Move the misplaced types** (groups 1 to 4), folder by folder, with no
   other change: wire types to `Model/`, `LocalText*` to `LocalText/`, the
   settings types beside `AppConfig`, the host extensions into `Core/`. Each PR
   shrinks the allowlist.
2. **Add seams for the genuine upward calls** (group 5): a protocol or closure
   per call, installed where the higher module is built, as `PlatformServices`
   installs the app's.
3. **Create the targets, bottom up,** one PR per module: move its folders under
   `Sources/<Module>`, add the target, change `internal` to `package` where the
   compiler asks, re-export it from `AlasCore`, and add `@testable import` of the
   new module to the app and package tests that use its internals. The layering check becomes
   the compiler's job and its allowlist is deleted once all targets exist.
4. **Measure and, if needed, split `AlasAgents`.** Record each module's peak
   compiler memory and the nightly's build step; split further only if a module
   misses the 2 GB budget or the nightly misses 60 minutes.

## Progress

- **Phases 0 and 1** are done: every misplaced type and file moved, and the
  layering check's allowlist emptied.
- **Phase 2 needed no seams.** Every upward call was a pure helper in the
  wrong place: it moved down, leaving a forwarder at its old name, so no
  protocol or closure was needed.
- **Phase 3 is one PR, not seven.** All seven targets exist; `AlasCore` holds
  only `Modules.swift`, which re-exports them. Every file of a target imports
  the targets it uses. Internals that cross a target now need `package`
  access, or an `@_spi(Testing)` import where the symbol was already SPI. The
  layering check and its allowlist are gone: the compiler enforces the
  boundaries.
- **Phase 4, measured locally** (`swift build -c release --target <module>`,
  bottom up, peak resident memory): AlasFoundation 0.3 GB, AlasModel 0.8,
  AlasPlatform 1.6, AlasFeatures 2.4, AlasCode 1.0, AlasAgents 2.8,
  AlasHostCore 1.6. Peak memory tracks size: modules up to about 27k lines
  stay near 1.6 GB, so each module is kept under about 30k.
- **AlasFeatures is split too**, which the plan did not expect: Integrations,
  Issues, Projects and Shepherd become `AlasIntegrations` (28k lines, 1.5 GB)
  above the rest of `AlasFeatures` (21k lines, 1.5 GB). The few lower files
  that used them moved up with them; `ReviewEvidenceStatus` and
  `WorkspaceRepairCandidate`, plain values, moved down.
- **AlasAgents is split in four,** not along `ACP/Session` and `ACP/Adapter`:
  `ACP/Session` alone was 40k lines, and its value types and its runtime
  depend on each other through the session and the runner. The cut follows
  the declarations instead: `AlasACP` (protocol, broker, adapter, remote and
  the session value types the rest uses; 28k lines, 0.9 GB), `AlasSessions`
  (`ACPSession`, its runner and store, and the plugin host that drives them;
  27k, 0.9 GB), `AlasAgentKit` (harness, schedules, agent registry; 11k,
  0.7 GB) and `AlasAgents` (the session manager; 13k, 1.6 GB). A type and its
  extensions in one file stay together; 32 files with declarations on both
  sides of a cut were split, and the private helpers they share became
  `package`. `AlasHostCore` above them peaks at 1.3 GB.

## Risks

- **Runtime performance.** Generic code called across a module boundary is no
   longer specialized by WMO in the caller. SwiftPM's default cross-module
   optimization covers much of it. The opt-in transcript benchmark
   (`AlasTests/ACPTranscriptFrameRateBenchmark`, `TEST_RUNNER_ALAS_TRANSCRIPT_BENCH=1`
   on an optimized build) runs before and after Phase 3, interleaved against the
   base commit, to check the hot paths.
- **Churn in open PRs.** Moves touch many files. Phase 1 lands in small,
   mechanical PRs (`git mv` plus imports) so conflicts stay easy to resolve.
- **`package` access sprawl.** Many `internal` declarations become `package`.
   That keeps them out of the app's API but makes the module boundary softer
   than it could be; tightening it is later work.

## Decided

- **Seven modules** as listed, split further only where Phase 4's measurements
  ask for it.
- **The umbrella stays:** `AlasCore` re-exports the modules, and the app and
  the tests keep importing `AlasCore`; only tests that use a module's internals
  also import that module.
