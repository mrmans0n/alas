# AGENTS.md - alas

## Project
- Repo: `mrmans0n/alas`
- Stack: Swift 5.9+ / SwiftUI macOS app, terminal via Ghostty Swift package
- Purpose: native workspace for git repos, linked worktrees, files, git changes, and persistent terminals — opinionated AI harness manager

## Development rules
- Keep code, comments, logs, and UI strings in English.
- Prefer small, reviewable changes with tests when practical.
- Tests use the Swift Testing framework (`import Testing`), not XCTest.
- After editing `project.yml`, regenerate the Xcode project with `xcodegen` and commit both files.
- `Info.plist` keys are pinned in `project.yml` under `info: properties:` — edit there, not the plist.
- Do not introduce large architectural changes without an explicit plan.
- Do not add agent attributions of any kind: no `Co-Authored-By: Claude` (or any other model/tool) trailers in commits, no "Generated with Claude Code" footers in PR/MR descriptions, no "🤖" markers, no "this was written by an AI" notes in code, comments, docs, or commit/PR bodies. Commits and PRs should read as if written by the human author.

## Before finishing a change

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```

## Shared GhosttyKit cache

`scripts/build-ghostty.sh` caches the built `GhosttyKit.xcframework` and
`share/{ghostty,terminfo}` per host, keyed by a fingerprint over the Ghostty
submodule (`HEAD` + working-tree diff + untracked files), the build script
itself, and `mise.toml`. A fresh worktree whose fingerprint matches an
existing entry skips zig entirely.

**Cache path:** `~/Library/Caches/Alas/GhosttyKit/<arch>/<fingerprint>/`

**Nuke everything:** `rm -rf ~/Library/Caches/Alas/GhosttyKit`

**Tunables (env vars):**

| Var | Default | Purpose |
|---|---|---|
| `ALAS_GHOSTTY_CACHE_DIR` | `~/Library/Caches/Alas/GhosttyKit` | Override the cache root. |
| `ALAS_GHOSTTY_CACHE_KEEP` | `5` | Number of fingerprint entries (per arch) to keep after GC. |
| `ALAS_GHOSTTY_CACHE_DISABLE` | unset | When `1`, skip the shared cache (read & write). |
| `ALAS_ZIG_BIN` | `$(brew --prefix zig@0.15)/bin/zig` | Override the zig binary. |
| `ALAS_GHOSTTY_LOCK_STALE_SECS` | `60` | Grace period before a lock is considered stale. |
| `ALAS_GHOSTTY_LOCK_TIMEOUT_SECS` | `1800` | Max wait before giving up on the lock and building locally. |

**Concurrency:** Two worktrees building the same fingerprint serialize on a
`mkdir`-atomic lock at `<cache-path>.lock/`. The winner builds and publishes;
the loser populates from the just-published cache. Stale locks (dead PID,
older than `ALAS_GHOSTTY_LOCK_STALE_SECS`) are reclaimed automatically.

**CI:** GitHub Actions is unaffected. The script's per-worktree fast path
(`.build/ghostty/fingerprint` match) wins before the shared cache is even
consulted, and CI uses `actions/cache` keyed off `.ghostty-pin` to restore
`.build/ghostty` directly.

## Tree-sitter grammars

All grammars live in `ThirdParty/treesitter-pack`, a Rust staticlib that
depends on them via cargo and exposes two lookups over a C ABI
(`alas_ts_language`, `alas_ts_query`). Highlight queries are compiled into the
binary, so there are no SPM resource bundles to locate at runtime. Only the
tree-sitter *runtime* (`SwiftTreeSitter`) still comes from SwiftPM.

**Add or update a grammar:**

1. Edit `ThirdParty/treesitter-pack/Cargo.toml`.
2. Register the id in `src/lib.rs` — the `extern "C"` entry point, `LANGUAGES`,
   and `QUERIES`. Crates whose query const is absent or commented out need
   their `.scm` copied into `queries/<id>/` (HCL and Dockerfile already are).
3. Map the file extension to the id in `LanguageRegistry.swift`.
4. `cd ThirdParty/treesitter-pack && cargo test` — the suite asserts every
   registered language resolves and every query is non-empty.

`scripts/build-treesitter-pack.sh` builds it, fingerprinting the crate's own
files (manifest, lockfile, sources, queries, header) plus arch, toolchain, and
script hash, so an uncommitted `lib.rs` edit invalidates the artifact. It also
refuses to publish an archive missing any grammar entry point — a crate that
drops out of the link graph fails the build instead of silently degrading a
language to plain text.

**Nuke the build:** `rm -rf .build/treesitter-pack`

## Xcode build-state remediation

Alas worktree-heavy development can leave many stale Xcode DerivedData entries
behind, especially for `Alas.xcodeproj` and the vendored Ghostty project. These
entries are large because each Xcode project path gets its own SwiftPM checkout,
build products, and index state.

**Inspect stale Alas/Ghostty DerivedData entries:**

```bash
scripts/prune-xcode-state.sh
```

**Delete only stale Alas/Ghostty DerivedData entries:**

```bash
scripts/prune-xcode-state.sh --delete
```

The pruner only considers `Alas-*` and `Ghostty-*` directories under
`~/Library/Developer/Xcode/DerivedData`. It keeps entries whose recorded
`WorkspacePath` still exists and ignores unrelated projects.

**Capture a memory/build snapshot during a bad episode:**

```bash
scripts/build-memory-snapshot.sh > /tmp/alas-build-memory.txt
```

The snapshot records VM pressure, top resident processes, Xcode/Swift/Zig build
processes, Alas/Ghostty DerivedData sizes, local build caches, and active git
worktrees.
