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

# 4. Pick the what's new highlights (see "What's new entries" below).
#    Skip this step to ship without a card.
$EDITOR Alas/Resources/WhatsNew/0.1.2.json
#    Optional media: Alas/Resources/WhatsNew/media/0.1.2-<slug>.gif (under ~2 MB)

# 5. Bump the version in project.yml, regenerate Xcode project.
$EDITOR project.yml   # bump CFBundleShortVersionString + CFBundleVersion
xcodegen

# 6. Commit and tag.
git add CHANGELOG.md project.yml Alas.xcodeproj Alas/Resources/WhatsNew
git commit -m "Bump version to 0.1.2"
git tag v0.1.2
git push origin main v0.1.2
```

The `Release Artifacts` workflow will pick up `v0.1.2`, build/sign/notarize
the app, extract the `[0.1.2]` section from `CHANGELOG.md`, and publish a
GitHub Release with that body. If `CHANGELOG.md` has no matching section the
workflow hard-fails — fix and re-tag.

## What's new entries

After updating, Alas shows a one-time "What's new" card for the newest entry
between the last-seen version and the running one. Stable builds only. Entries
are curated by hand at release time; a release with no entry shows no card.

In step 4, read the new version's `✨ Features` section and pick one headline
and up to two "also" items, or none. Rewrite them as short marketing copy, not
the changelog sentence. "None" means no file.

Entries live in `Alas/Resources/WhatsNew/<version>.json`, bundled into the app:

```json
{
  "version": "0.22.0",
  "headline": {
    "title": "Plugins",
    "body": "Extend Alas with your own panes and commands.",
    "media": "media/0.22.0-plugins.gif",
    "action": "openPluginSettings",
    "actionLabel": "Try plugins"
  },
  "also": [
    { "title": "@ symbols in composer" },
    { "title": "Faster worktrees" }
  ]
}
```

- `version` must equal the filename stem (`0.22.0.json`).
- `headline.title` and `headline.body` are required; the body is one sentence.
- `media` is optional, relative to the `WhatsNew` folder, and must stay inside
  it. Convention: `media/<version>-<slug>.gif`, under ~2 MB.
- `action` is optional and must be one of the identifiers below. `actionLabel`
  is the button text and defaults to "Try it".
- `also` is optional, at most two items.

Valid `action` identifiers (defined by `WhatsNewAction` in
`Packages/AlasCore/Sources/AlasCore/Updates/WhatsNew.swift`):

| Action | Effect |
|---|---|
| `openPluginSettings` | Opens Settings → Plugins |

Adding an action is an app change (a new `WhatsNewAction` case plus its
handling in `RootView`), shipped with the feature it showcases.

To preview an entry locally, run a build whose version is at or above the
entry and use Help → What's New…, which reopens the newest entry at or below
the running version.

Entries are validated by the `committedEntriesAreValid` test in `WhatsNewTests`:

```bash
swift test --package-path Packages/AlasCore --filter WhatsNewTests
```

The release workflow runs it in the `whats-new-check` job, and `publish`
needs that job, so an invalid entry (bad JSON, version/filename mismatch,
missing media, unknown action, more than two `also` items) blocks the release.

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
