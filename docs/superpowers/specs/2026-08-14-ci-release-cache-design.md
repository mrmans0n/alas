# CI Release Cache Design

## Problem

Release builds repeatedly compile dependencies that already succeeded on
trusted `main` builds. Release `v0.14.11` spent 11–14 minutes per architecture
building Ghostty, while the x86_64 leg spent another 13 minutes building zmx,
fff, Alas Helper, and Alas CLI. The two Xcode Release builds then took 30 and
38 minutes. Signing, packaging, notarization, and upload took about three
minutes per architecture.

The caches do not currently preserve the expensive work effectively:

- PR and nightly builds cache `.build/ghostty` under a non-architecture key,
  while releases cache the smaller shared Ghostty directory under an
  architecture-qualified key. GitHub therefore cannot match the default-branch
  cache for release jobs.
- Trusted `main` workflows produce only arm64 tool caches, so tag-triggered
  x86_64 release jobs have no default-branch cache to restore.
- CI saves an immutable Swift compilation-cache snapshot for every commit. One
  active PR occupied roughly 7.3 GB of the repository cache quota, evicting the
  shared `main` snapshot. Recent runs did not show a reliable wall-time benefit:
  a build with 84% cache hits took 18 minutes 45 seconds, while a cold `main`
  build took 15 minutes 10 seconds.

## Goals

- Keep version tags and exact tag checkout as the release source of truth.
- Remove repeated release dependency builds without skipping validation,
  signing, notarization, packaging, or Homebrew verification.
- Keep every restored binary subject to the build scripts' existing
  fingerprint validation.
- Bound cache usage so useful shared caches are not evicted by per-commit
  snapshots.

## Design

### Shared Ghostty Cache

`build.yml`, `nightly.yml`, and `release.yml` will use the same cache path and
key shape:

```text
~/Library/Caches/Alas/GhosttyKit/<arch>
ghostty-<runner-os>-<arch>-<pin-hash>
```

The arm64 PR/main build will restore this shared directory before running
`build-ghostty.sh`. The script will populate `.build/ghostty` from the restored
entry, preserving the existing local output expected by Xcode. On a miss it
will build, validate, and publish the fingerprinted entry before the workflow
saves it.

This replaces the current approximately 871 MB `.build/ghostty` archive with
the approximately 128 MB shared-cache archive. A tag-triggered release can
restore the matching entry from the default `main` branch scope.

### Nightly x86_64 Dependency Warmer

`nightly.yml` will add an independent job that runs only for scheduled builds
and manual builds of `main`. It will:

1. Check out `main` with recursive submodules.
2. Install the existing pinned build tools.
3. Restore x86_64 Ghostty and prebuilt-tool caches.
4. Run the existing Ghostty, zmx, fff, Alas Helper, and Alas CLI build scripts
   with the same architecture overrides used by `release.yml`.
5. Save successful cache misses immediately.

The warmer will not build the app, receive signing or notarization secrets,
publish artifacts, or delay the existing arm64 nightly job. Manual nightly
runs for non-main refs will skip it, so feature-branch scripts cannot seed
trusted default-branch caches.

The combined tools cache remains unchanged. Alas Helper and Alas CLI already
build all required targets and validate a source-and-script fingerprint; zmx
and fff additionally validate their requested architecture.

### Release Restore Behavior

`release.yml` will retain its tag, published-release, and manual triggers and
will continue checking out the exact release tag. Its Ghostty cache path and
key will match the shared format above. Its existing arch-qualified tools key
will consume the x86_64 cache produced by nightly.

The x86_64 tools restore will also fall back to the trusted arm64 tools cache.
This allows architecture-independent Alas Helper and Alas CLI outputs to
fast-path if the x86_64 cache is absent; zmx and fff will reject mismatched
fingerprints and rebuild their x86_64 outputs.

### Swift Compilation Cache

`build.yml` will remove cross-run Swift compilation-cache restore, reporting,
and save steps, along with the build-only cache enablement flag. This removes
the per-commit immutable snapshots responsible for cache-quota churn. Existing
entries can expire through GitHub's normal cache eviction; the workflow will
not add deletion permissions or cache-maintenance scripting.

Both PR and release Xcode invocations will enable Xcode's build timing summary
so subsequent optimization decisions use measured task timings. This changes
logging only.

## Failure and Security Behavior

- A cache miss remains a supported cold build, not a workflow failure.
- Cache saves occur only after the corresponding build scripts succeed.
- Existing script fingerprints continue covering source revisions, local
  changes, scripts, architecture, and relevant toolchain identity.
- Tag releases may read trusted default-branch caches but cannot overwrite
  them; nightly writes x86_64 caches only while building `main`.
- Signing, notarization, package verification, and Homebrew verification remain
  unchanged.

## Validation

- Run the existing build-script harnesses, especially the Ghostty, zmx, fff,
  Alas Helper, and Alas CLI cache and fingerprint tests.
- Regenerate the Xcode project and run the required macOS build and test
  commands.
- Validate workflow syntax locally if an installed checker is available.
- Dispatch nightly against the feature ref to verify the ordinary nightly path
  while confirming the main-only x86_64 warmer is skipped.
- After merge, confirm one scheduled nightly creates arm64 and x86_64 caches in
  the `refs/heads/main` scope. The next tag release should report exact cache
  hits and dependency prebuild steps should complete in seconds.
- Compare the Xcode timing summaries across several PR and release runs before
  considering Release compilation caching or larger runners.

## Expected Result

In steady state, dependency preparation in both release matrix legs should
complete in seconds. Release wall time should fall from roughly 70 minutes to
approximately 40–45 minutes and become dominated by the unchanged Xcode
Release compile. PR behavior remains fully validated while avoiding compiler
cache restore/save overhead and quota churn.

## Out of Scope

- Skipping or reducing tests, signing, notarization, packaging, or publication
  verification.
- Replacing tag-triggered releases with a manual release process.
- Adding self-hosted or paid larger runners.
- Caching Release-mode Xcode compilation outputs before timing data shows a
  reliable benefit and a bounded storage strategy is defined.
