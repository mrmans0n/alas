# Releasing alas

Alas releases ship a signed + notarized macOS DMG, an `Alas-X.Y.Z-arm64.app.zip`,
and a Homebrew cask bump in `mrmans0n/homebrew-tap`. All of that runs from
`.github/workflows/release.yml` on tag push.

This doc covers the human side: cutting `CHANGELOG.md` and bumping the version.

## Cutting a release

```bash
# 1. Draft entries from commits since the last v* tag.
./scripts/draft-release-notes.sh --write

# 2. Open CHANGELOG.md and polish the [Unreleased] section.
$EDITOR CHANGELOG.md

# 3. Promote the curated notes into the new version section.
./scripts/draft-release-notes.sh --target 0.1.2 --write

# 4. Bump the version in project.yml, regenerate Xcode project.
$EDITOR project.yml   # bump CFBundleShortVersionString + CFBundleVersion
xcodegen

# 5. Commit and tag.
git add CHANGELOG.md project.yml Alas.xcodeproj
git commit -m "Bump version to 0.1.2"
git tag v0.1.2
git push origin main v0.1.2
```

The `Release Artifacts` workflow will pick up `v0.1.2`, build/sign/notarize
the app, extract the `[0.1.2]` section from `CHANGELOG.md`, and publish a
GitHub Release with that body. If `CHANGELOG.md` has no matching section the
workflow hard-fails — fix and re-tag.

## Draft script flags

- `--since <ref>` — override the base ref (default: latest reachable `v*` tag).
- `--target <version>` — render under a versioned heading instead of `[Unreleased]`.
- `--write` — splice into `CHANGELOG.md` rather than printing.
- `--include-internal` — include `ci`/`test`/`build`/`style` commits under
  `🏗️ Internal` (default skips them).

## Conventional commit prefixes

| Prefix | Where it lands |
|---|---|
| `feat:` | ✨ Features |
| `fix:` | 🐛 Fixes |
| `refactor:`, `perf:`, `chore:` | 🏗️ Internal |
| `docs:` | 📚 Docs |
| `ci:`, `test:`, `build:`, `style:` | dropped unless `--include-internal` |

PR titles follow the same convention since the repo uses squash merges.
