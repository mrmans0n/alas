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

## Local baseline

Measured at the same base revision on an Apple M1 Max, 10 logical CPUs, 32 GiB
RAM, macOS 26.6.2, Xcode 26.4.1. Builds use four Xcode jobs, Debug arm64, unsigned
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

All four commands exited zero. Native artifacts and SwiftPM checkouts were prepared
before the timed runs. The no-op run executed zero compiler tasks. Local evidence
is retained in `.build/measurements/cold` and `.build/measurements/noop`, including
the command, raw output, result bundle, activity JSON, and summary. The baseline
DerivedData is preserved in `.build/measurements/uncached-derived-data` while the
cache trial uses the original `.build/xcode/DerivedData` path.

The cache seed reported 284 Swift misses and 72 Clang misses. The rebuild with
fresh DerivedData reported 284 Swift hits and 72 Clang hits, with no reported
misses. The compiler cache occupied about 1.9 GiB on disk. The faster cold seed
than the uncached baseline should not be credited to caching: host contention
changed between observations. The 49.849-second replay establishes actual reuse
independently of that variation. Evidence is in `.build/measurements/cas-cold`
and `.build/measurements/cas-replay`.

Debug builds enable Xcode's compilation cache. CI points it at
`.build/xcode/CompilationCache.noindex`; local builds use Xcode's default cache
location unless the caller overrides it. CI snapshots include toolchain, SDK,
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
