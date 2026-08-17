# Remove Missions

## Goal

Remove the unused experimental Missions feature and its feature flag without removing shared behavior used by the production app.

## Scope

- Delete Mission models, persistence, coordination, UI, tests, and feature-flag code.
- Remove Mission wiring from app state, root/sidebar/center presentation, tabs, settings, paths, and closed-tab history.
- Delete Mission-specific design and implementation documents.
- Regenerate the Xcode project after source deletion.

## Production Compatibility

- Preserve code-host providers, worktree creation, ACP session bootstrap, normal tab management, and normal closed-tab restoration even where those foundations were originally introduced in Mission commits.
- Keep tolerant worktree-tab decoding so persisted Mission tab cases are ignored without preventing supported tabs from restoring.
- Do not delete users' existing `missions.sqlite`, `global-tabs.json`, or feature-flag defaults. The app will simply stop reading them.
- Keep historical changelog entries.

## Verification

- Search production sources and tests for remaining Mission symbols, UI copy, feature-flag keys, and documentation.
- Run `xcodegen`.
- Build the macOS app.
- Run the full test suite.
