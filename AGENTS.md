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
