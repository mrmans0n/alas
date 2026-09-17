# Swift build measurements

Issue [#1273](https://github.com/mrmans0n/alas/issues/1273) measures compilation
after the native-build fixes in #1274 and #1276. Test execution and its coverage
audit are described in [Swift CI coverage](swift-ci.md).

## Measurement rules

Record the revision, host, Xcode/Swift/SDK versions, configuration, destination,
package resolution, native artifact state, command, exit status, and wall time.
Keep native preparation and package resolution outside the timed Swift build.
A cold Swift build can still use warm native artifacts and package downloads;
label those states separately.

`scripts/swift_build_metrics.py run` preserves the command, elapsed wall time,
exit code, and complete output in a new evidence directory. It refuses to
overwrite a previous measurement. `report` extracts structured activity from
the result bundle and groups compilation into app, tests, dependencies, and
scripts. Summed task durations include overlapping work. Active seconds merge
overlapping intervals within each group, but groups can also overlap. Neither
column is the group's contribution to the critical path.

Use compiler cache diagnostics to establish replay. A restored archive or a
fast build alone does not establish that the compiler reused outputs. Measure
archive size, restore, and upload time as well as compilation. A cache has a
net benefit only when the saved compilation time exceeds the transfer overhead.

## Local commands

Keep one DerivedData directory per worktree, and use it across that worktree's
builds. The built-in Build script uses `.build/xcode/DerivedData`. Run only one
build at a time against that directory. A fresh worktree needs its own native
artifacts and package checkouts before comparing Swift build time.

```sh
git submodule update --init ThirdParty/ghostty ThirdParty/zmx ThirdParty/fff
scripts/build-ghostty.sh
xcodegen
xcodebuild -resolvePackageDependencies -project Alas.xcodeproj -scheme Alas \
  -clonedSourcePackagesDirPath .build/xcode/SourcePackages

xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode/DerivedData \
  -clonedSourcePackagesDirPath .build/xcode/SourcePackages build

xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode/DerivedData \
  -clonedSourcePackagesDirPath .build/xcode/SourcePackages \
  -only-testing:AlasTests/SemanticVersionTests test
```

`-only-testing` narrows execution. It does **not** prune compilation of the
single `AlasTests` target. To repeat execution after a successful
`build-for-testing`, use `test-without-building` with the same build settings
and paths. Rebuild after changing sources or configuration. Do not routinely
clean DerivedData or bypass native fingerprints.

For a timed build, choose a new evidence name for each run:

```sh
python3 scripts/swift_build_metrics.py run --output .build/measurements/noop -- \
  xcodebuild -project Alas.xcodeproj -scheme Alas -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode/DerivedData \
  -clonedSourcePackagesDirPath .build/xcode/SourcePackages \
  -resultBundlePath .build/measurements/noop/build.xcresult \
  -showBuildTimingSummary build-for-testing
python3 scripts/swift_build_metrics.py report --output .build/measurements/noop \
  --result .build/measurements/noop/build.xcresult
```

## CI baseline

The base revision `891441e0cd77f1bedfd30796591de1bfb1b750bc` passed
[run 35269205192](https://github.com/mrmans0n/alas/actions/runs/35269205192).
Its build step ran from 20:12:22 to 20:29:08 UTC on September 17, 2026:
**1006 seconds wall time** with cold DerivedData and warm native/package caches.
The timing summary reported 2507.201 summed SwiftCompile seconds, 174.988
SwiftEmitModule seconds, and 3.581 script seconds. SwiftPM cache restore took
28 seconds. This run predates the measurement tool, so its summary does not
separate app and test compilation reliably.

The preceding revision's
[run 35265066974](https://github.com/mrmans0n/alas/actions/runs/35265066974)
took 795 seconds for the build, 2012.301 summed SwiftCompile seconds, and 3.256
script seconds. These runs contain different sources and are context for runner
variability, not a controlled before/after comparison.

## CI compilation-cache trial

The PR's [run 35275732170](https://github.com/mrmans0n/alas/actions/runs/35275732170)
measures merge revision `cc24e6e0e10d21ef9604dc4fa22c5b2fbaacea65`. Unlike the
local diagnostic runs, CI does not add type-check warning flags. Native and
package caches are warm; DerivedData is fresh on every runner.

| Run | Command wall seconds | App active seconds | Tests active seconds | Dependencies active seconds | Scripts active seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| [Cold compiler cache](https://github.com/mrmans0n/alas/actions/runs/35275732170/job/105385786020) | 646.003 | 230.055 | 350.101 | 21.577 | 1.871 |
| [Restored compiler cache, fresh runner and DerivedData](https://github.com/mrmans0n/alas/actions/runs/35275732170/job/105393518092) | 109.602 | 11.672 | 13.818 | 5.204 | 3.254 |

The seed reports 264 Swift misses and 72 Clang misses. Its compressed Actions
cache is 350,021,984 bytes, from 1,619,872 KiB on disk. The save step, including
compression and upload, took 11 seconds. The initial cache lookup took less than one second and found
no entry. Build measurements are published as `swift-build-metrics-1`, including
the raw compiler log, result bundle, activity JSON, and summary.

Attempt 2 rebuilt the same merge revision on a different runner. It reported
264 Swift hits and 72 Clang hits, with no reported misses. The restore step took
13 seconds, including download and extraction. The exact-key hit requires no
upload. Build plus restore therefore took 122.602 seconds. Even charging the
seed's measured 11-second upload cost gives 133.602 seconds, about 79% below the
646.003-second cold compilation baseline. These observations justify adopting
the compiler CAS cache in CI. They do not predict the hit rate of an arbitrary
source-changing commit; the source and settings probes below verify invalidation.
Warm evidence is published as `swift-build-metrics-2`.

This is a build-segment improvement, not a measured reduction in total workflow
latency. The warm attempt's builder waited 18m51s for a runner, from 21:41:58 to
22:00:49 UTC. Queueing and distributed test execution remain separate concerns.
The cold attempt passed the builder, both Swift shards, and the coverage audit.
Its unrelated AlasCLI socket test failed with `Connection reset by peer`.
The AlasCLI job passed in attempt 2 without any source change.

## Local baseline

Local runs use the base revision's app and test sources, apart from the temporary
edit probes below. The existing worktree advanced to trial commit `cd6e8ab6`
for the later measurements; the fresh worktree remained at `891441e0`.
The host is an Apple M1 Max, 10 logical CPUs, 32 GiB RAM, macOS 26.6.2,
Xcode 26.4.1. Builds use four Xcode jobs, Debug arm64, unsigned
products, and the same diagnostic thresholds: 200 ms for function bodies and
100 ms for expressions. Other worktrees were compiling concurrently. These are
single observations under contention, not a statistically controlled estimate
of this machine's best build time.

| Run | Command wall seconds | App active seconds | Tests active seconds | Dependencies active seconds | Scripts active seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold DerivedData, compilation cache off | 777.616 | 290.174 | 413.309 | 35.369 | 4.064 |
| Same worktree, no edit, same settings | 12.883 | 0 | 0 | 0 | 3.530 |
| Cold DerivedData and cold compiler cache | 577.632 | 156.134 | 373.621 | 16.519 | 3.561 |
| Fresh DerivedData at the same path, populated compiler cache | 49.849 | 2.749 | 3.681 | 2.299 | 5.105 |
| Same worktree, compiler cache on, no edit | 5.472 | 0 | 0 | 0 | 1.532 |
| Same worktree, first implementation edit after CAS replay | 304.238 | 289.888 | 0 | 0 | 1.803 |
| Same implementation edit, compiler cache off | 40.732 | 27.083 | 0 | 0 | 1.617 |
| Final project defaults, same-worktree no-op | 5.408 | 0 | 0 | 0 | 1.381 |
| Fresh worktree, fresh DerivedData, populated shared compiler cache | 401.610 | 144.162 | 216.749 | 13.855 | 4.407 |
| Fresh worktree, subsequent no-op | 4.152 | 0 | 0 | 0 | 1.451 |
| Fresh worktree, same implementation edit after actual compilation | 38.086 | 24.941 | 0 | 0 | 1.390 |

All listed commands exited zero. Native artifacts and SwiftPM checkouts were prepared
before the timed runs. The no-op run executed zero compiler tasks. Local evidence
is retained in `.build/measurements/cold` and `.build/measurements/noop`, including
the command, raw output, result bundle, activity JSON, and summary. Baseline
DerivedData was moved aside while the cache trial used the original
`.build/xcode/DerivedData` path, then restored for the uncached edit comparison.
The final working build directory uses ordinary incremental compilation.

The fresh checkout has its own generated project, native artifacts, package
checkouts, and DerivedData under `.build/measurements/fresh-worktree`. Native
artifacts and package downloads were copied before timing. Its first build used
the original worktree's populated CAS through an absolute path, without copying
DerivedData. It reported 142 Swift hits, 142 Swift misses, 23 Clang hits, and 49
Clang misses. The raw log reports misses for all 40 app and 36 test compiler
tasks. Shared SDK reuse does not imply source-output reuse across worktree paths.
The fresh no-op scheduled no compiler tasks. Its subsequent implementation edit
scheduled two app compiler tasks and reported two Swift misses. These runs
overlapped the short uncached local checks, so their wall times also include
host contention.

The cache seed reported 284 Swift misses and 72 Clang misses. The rebuild with
fresh DerivedData reported 284 Swift hits and 72 Clang hits, with no reported
misses. The compiler cache occupied about 1.9 GiB on disk. The faster cold seed
than the uncached baseline should not be credited to caching: host contention
changed between observations. The 49.849-second replay establishes actual reuse
independently of that variation. Evidence is in `.build/measurements/cas-cold`
and `.build/measurements/cas-replay`.

The small edit replaced string interpolation in `SemanticVersion.description`
with an equivalent `map`/`joined` expression. The first edit after the existing
worktree's full CAS replay scheduled all 40 app compiler tasks, with 40 Swift
misses, but no test or dependency compilation.
Ordinary incremental compilation scheduled just two app tasks for the same edit,
the changed file and module emission, and completed in 40.732 seconds. That run
overlapped the separate fresh-worktree benchmark, yet remained much faster.
The fresh worktree's edit after actual compilation also scheduled just two tasks
with caching enabled and took 38.086 seconds. These observations do not establish
a general incremental-build regression or a local caching benefit. They do show
an expensive first edit after replay that should not be hidden by quoting only
the fast unchanged replay. Keep the existing local defaults; the proposed Debug
cache default was rejected for lack of a demonstrated net local benefit.
Eight `SemanticVersionTests` passed from the replayed build products, after the
edit in both worktrees, and on the final restored local configuration. The
temporary edit is not an optimization proposed by this change.

Invalidation probes used the populated cache without changing its outer key:

- Adding a temporary `#error` to `SemanticVersion.swift` failed the build with
  that exact diagnostic in 9.019 seconds, rather than replaying stale success.
- Setting `SWIFT_SUPPRESS_WARNINGS=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` scheduled
  dependency compilation, reported 20 Swift misses, and failed in 5.334 seconds
  on `swift-markdown` Sendable warnings promoted to errors. An earlier attempt
  without overriding warning suppression failed at driver argument validation.
- Restoring the normal settings succeeded in 22.333 seconds with 49 Swift hits.
  Removing the source probes and restoring the original implementation then
  succeeded in 24.895 seconds with 37 Swift hits and one miss.

CI explicitly enables Xcode's compilation cache and points it at
`.build/xcode/CompilationCache.noindex`. Local builds keep ordinary incremental
compilation. To reproduce the cache trial, explicitly pass
`COMPILATION_CACHE_ENABLE_CACHING=YES`,
`COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES`, and an absolute
`COMPILATION_CACHE_CAS_PATH` to `xcodebuild`. CI snapshots include toolchain, SDK,
OS, architecture, checkout root, project settings, package lockfile, and workflow
configuration in their compatibility key. Each commit can save a new snapshot,
and fallback restores stay within that compatibility prefix. Xcode constructs
a new build graph for each checkout and checks compiler inputs against the CAS.
No source timestamps are rewritten and no DerivedData or test products are
restored by the compilation-cache step.

The diagnostic run identified these app hotspots:

| Location | Type-check milliseconds |
| --- | ---: |
| `DiffPaneView.lineNumberGutterThickness(rows:)` | 8886 |
| `CenterPaneView.body` | 7119 |
| `DraftCommitTabView.hasStaged` | 5649 |
| `EditorTabView.body` | 5162 |
| `MarkdownTabView.resolvedMode` | 5038 |

Function and nested-expression warnings describe overlapping work, so do not
sum them. Contention affects these timings too. The longest expression is the
`flatMap` / `compactMap` / `map` chain for diff gutter digits. These observations
identify focused follow-up candidates; they do not establish that moving code
between modules or test targets would improve end-to-end time.
