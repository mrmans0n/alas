# LSP Install Nudge Mason Fallback Plan

## Problem Statement

The editor install nudge only appears when a file extension resolves to an enabled `LanguageServerRegistry` entry and that language has install recipes from `RecommendedLanguageCatalog` or `AppConfig.code.userDefinedRecipes`. Files whose extensions are only known to the bundled Mason snapshot, such as a future `.toml` entry, currently get no in-editor affordance. The feature should add a Mason-backed fallback for extensions without an enabled registry match, install through the existing installer flow, and persist a language server config so the newly installed server can actually spawn afterward.

## Decisions

### Multiple Mason Packages Per Extension

Chosen option: show a small package picker in the banner when an extension has more than one installable Mason match.

Rationale: a single automatic pick is risky for extensions like `py`, `css`, `yaml`, and `json`, where the best server depends on project intent. A picker keeps the banner useful without sending the user to Settings, and it mirrors the existing settings prefill pattern while preserving `InstallSplitButton` for the second choice axis: installer recipe selection. The picker should be bounded, deterministic, and quiet: sort exact primary-language matches first, then packages whose `languageId` is non-empty, then stable `masonId`; show a short top-N list with a "More in Settings" follow-up only if needed.

### Missing Snapshot Packages

Chosen option: split into two shippable work items.

Phase A adds the banner fallback against the current snapshot. It improves all extensions already present in `mason-lsps.json` and does not depend on regenerating resources. Phase B broadens the generator so packages like `taplo` can enter the snapshot. `taplo` is currently skipped because its Mason source is `pkg:github/*`; since Homebrew has a `taplo` formula, the generator should keep GitHub-sourced LSPs when the exact-name brew probe succeeds, producing a brew-only recipe instead of skipping them.

### Persisting Newly Discovered Languages

Chosen option: factor the settings save path into shared code and call it from the banner after a Mason install succeeds.

Rationale: the banner must write a `LanguageServerConfig` plus `userDefinedRecipes[languageId]`, matching `CodeLanguageDetailView.applyPrefill(_:)` and `CodePane.save`. The shared helper should normalize the config, upsert by language id, write recipes when present, call `saveConfig()`, and rely on `saveConfig()` to update the live `WorkspaceLSPManager` registry. The generated config should use `pkg.languageId` when present, fall back to `pkg.masonId.lowercased()`, copy `extensions`, `command`, and `args`, and default `env` to `[:]`, `rootMarkers` to `[".git"]`, and `enabled` to `true`.

### Dismissal Key

Chosen option: use namespaced extension keys for Mason-only nudges, e.g. `extension:toml`, while keeping existing language-id keys for registry-backed nudges.

Rationale: before install there is no durable app language id, and package ids would make dismissal leak through alternate suggestions for the same file. Extension-scoped dismissal matches what the user dismissed: "do not ask me about this file type." The namespace avoids collisions with real language ids and preserves the existing reset-dismissed-nudges setting.

### Mason Extension Lookup

Chosen option: add `MasonSnapshot.packages(forExtension:)`.

Rationale: the current `search(_:)` API is query-oriented and should not be overloaded for exact extension lookup. The new API should normalize a leading dot away, lower-case the extension, return packages whose `extensions` contain it, and keep snapshot order after applying a deterministic ranking helper used by the banner.

### Fallback Scope And Gating

Chosen option: keep the existing registry-backed path as the first branch, and only consult Mason when there is no enabled registry language for the extension and no disabled registry entry intentionally claiming it.

Rationale: this feature is for file types without built-in app coverage, not for changing recommendations for existing languages. Mason candidates should be filtered to packages with non-empty recipes and at least one detected installer via `installerHost.allAvailable`. If a package command is already installed but no config exists, treat that as later UX polish for a configure-only action rather than expanding Phase A beyond the install nudge.

### Disabled Registry Entries

Chosen option: do not show the Mason fallback when a disabled registry entry claims the extension and no enabled entry does.

Rationale: disabling a language in Settings is user intent to suppress that LSP path. The fallback should only cover "unknown to the enabled registry," not override a disabled built-in or user config. Implementation should explicitly check `registry.allEntries()` for disabled extension matches before consulting Mason.

### Sheet Survival

Chosen option: preserve the current outer-container `.sheet` placement in `InstallNudgeBanner`.

Rationale: the existing comment documents a real lifecycle issue: when installation flips availability and the banner unmounts, a sheet attached to the conditional banner loses the Done/Close callback. Any refactor must keep the sheet mounted on the always-present outer container.

### Reopening Unknown-Extension Buffers

Chosen option: extend the reopen path so buffers with no prior language can re-resolve after config persistence.

Rationale: existing `TabsManager.reopenLSPDocuments(forLanguage:)` only finds buffers whose `EditorBuffer.language` was already set. Unknown-extension buffers start with `nil`, so the new flow needs a targeted re-resolve path, such as `reopenLSPDocuments(forExtension:language:)` or an `EditorBuffer` method that resolves and stores the language before opening.

## Phased Work

### Phase A: Banner-Side Mason Fallback

Independently shippable outcome: extensions already present in the bundled snapshot can show an install nudge, install a selected Mason package, persist config, and wake the current/open buffers.

Files:

- `Alas/Sources/Code/LSP/Install/MasonSnapshot.swift`: add `packages(forExtension:)`, extension normalization, and ranking helpers.
- `Alas/Sources/Code/Editor/InstallNudgeBanner.swift`: split nudge data into registry-backed and Mason-backed cases; preserve outer sheet; add package picker state for Mason matches; filter Mason packages through non-empty recipes and `installerHost.allAvailable`.
- `Alas/Sources/Settings/CodePane.swift` and/or a new small helper near settings/persistence: move the language-server upsert logic out of private `CodePane.save` so the banner can reuse it.
- `Alas/Sources/Settings/CodeLanguageDetailView.swift`: reuse the same Mason prefill-to-config helper rather than duplicating mapping logic.
- `Alas/Sources/Center/TabsManager.swift` and `Alas/Sources/Code/Editor/EditorBuffer.swift`: add a re-resolve/reopen path for buffers that previously had no LSP language.

### Phase B: Snapshot/Generator Broadening

Independently shippable outcome: regenerated `mason-lsps.json` includes `taplo` and other GitHub-sourced LSPs when the generator can produce a supported installer recipe.

Files:

- `scripts/build-mason-snapshot.sh`: change `pkg:github/*` handling from unconditional skip to "keep if exact-name brew probe succeeds"; leave unsupported GitHub-only packages out.
- `Alas/Resources/mason-lsps.json`: regenerate after script change; verify `taplo` has `extensions: ["toml"]`, `languageId: "toml"`, command data, and a brew recipe.
- Potentially `AlasTests/Code/LSP/Install/MasonSnapshotTests.swift`: assert the bundled snapshot has a TOML match once regenerated.

### Phase C: UX Polish

Independently shippable outcome: the fallback feels intentional rather than a raw package list.

Files:

- `Alas/Sources/Code/Editor/InstallNudgeBanner.swift`: tune copy for Mason-only suggestions, e.g. "Install an LSP for .toml files"; show selected package display name and command; keep the installer split button concise.
- `Alas/Sources/Settings/CodePane.swift`: optionally add a settings affordance from dismissed extension nudges or a prefiltered Add-language entry for the extension.
- `Alas/Sources/Settings/CodeLanguageDetailView.swift`: optionally accept an initial prefill query or package when launched from the banner/settings affordance.

## Test Plan

Unit tests:

- `MasonSnapshotTests`: add exact extension lookup tests, dot-prefix normalization, case-insensitivity, no empty-extension matches, deterministic ordering, and no result cap unless intentionally capped by the new API.
- Add tests around the shared language-server persistence helper: upsert new Mason config, replace existing language config, write `userDefinedRecipes`, preserve recipes on rename if the existing settings behavior remains in scope, and keep normalized command/args.
- Add focused tests for disabled-entry policy if `LanguageServerRegistry` gains helper APIs for extension classification.
- Existing `LSPInstallerTests` and `LanguageServerAvailabilityTests` remain the model for pure argv/PATH behavior; no installer subprocess tests are needed for the banner fallback.

Manual editor checks:

- Open a file whose extension exists in the current snapshot but is not built in; verify the banner appears only when at least one recipe has an available installer.
- For an extension with multiple matches, verify package selection changes the displayed command and install recipes.
- Dismiss a Mason-only nudge, restart the app, and confirm it stays dismissed via `extension:<ext>`.
- Install from a Mason-only nudge and confirm `config.code.languageServers` and `userDefinedRecipes` are written, `AppState.refreshInstallerHost()` runs, and the open editor buffer starts LSP behavior without closing/reopening.
- After Phase B, open `.toml` and verify `taplo` is suggested on a machine with Homebrew available.

## Risks And Rollback

The highest risk is writing a bad `LanguageServerConfig` from the banner, because that can claim an extension and affect future editor opens. Mitigate by centralizing Mason prefill persistence, writing only after successful install, and keeping root markers conservative. Rollback is straightforward: remove the Mason fallback branch and leave persisted user configs untouched, since users can edit or disable them in Settings.

The second risk is noisy or wrong suggestions for overloaded extensions. The picker and disabled-entry policy reduce surprise; if the picker proves too busy, Phase A can be rolled back to "show fallback only when exactly one installable Mason package matches" without changing the snapshot API.

The generator change risks increasing snapshot size or adding packages with unsupported install paths. Keep Phase B constrained to GitHub-sourced packages that also have an exact Homebrew formula, and review the regenerated JSON diff before shipping.
