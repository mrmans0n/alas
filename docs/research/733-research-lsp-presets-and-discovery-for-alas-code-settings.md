---
task_id: 733
title: Research LSP presets and discovery for Alas Code settings
date: 2026-05-09
project: alas
---

# LSP Presets and Discovery for Alas Code Settings

## Problem Statement

Alas currently ships a single built-in LSP entry (Swift/sourcekit-lsp). Users working in Rust, Kotlin, TypeScript, JavaScript, JSON, or Markdown have no guided path to configure language servers. The goal is to expose installable and discoverable LSP options in Settings > Code while keeping the system extensible for custom servers.

## Recommended Preset List

The following servers were selected for broad adoption, reliable maintenance, and straightforward installation on macOS:

| Language(s) | Server | Executable | Args | macOS Install |
|---|---|---|---|---|
| Swift | sourcekit-lsp | `sourcekit-lsp` | — | Ships with Xcode; detect via PATH then `xcrun --find sourcekit-lsp` |
| Rust | rust-analyzer | `rust-analyzer` | — | `rustup component add rust-analyzer rust-src` or `brew install rust-analyzer` |
| TypeScript, JavaScript | typescript-language-server | `typescript-language-server` | `--stdio` | `npm install -g typescript-language-server typescript` |
| JSON, JSONC | vscode-json-language-server | `vscode-json-language-server` | `--stdio` | `npm install -g vscode-langservers-extracted` |
| Kotlin | kotlin-lsp (JetBrains) | `kotlin-lsp` | — | `brew install JetBrains/utils/kotlin-lsp` |
| Markdown | marksman | `marksman` | — | `brew install marksman` |

### Notes on Specific Servers

- **TypeScript and JavaScript** share the same server process. The current config model keys by a single `language`, so these two need a shared server definition with distinct LSP `languageId` values (`typescript` vs `javascript`). This is the most important data-model change.
- **JSON** package naming is inconsistent across npm: detection should accept both `vscode-json-language-server` and `vscode-json-languageserver`.
- **Kotlin LSP** is official from JetBrains but still pre-alpha. It should be marked `experimental` in the UI and may require pull-diagnostics client capability.
- **Markdown**: Marksman is the simpler, more compatible choice. VS Code's built-in Markdown LS requires custom client requests. An alternative is `markdown-oxide` (`brew install markdown-oxide`), but Marksman is recommended as the initial preset.

## Preset vs Discovery Strategy

Both mechanisms are needed and complement each other:

**Presets** are the source of truth for what Alas knows how to configure. Each preset defines: command, args, environment, language bindings, file extensions, root markers, install commands, detection rules, documentation URL, and stability status.

**Discovery** runs locally and asynchronously to answer "is this preset usable on this machine?" It searches PATH, common tool shims (e.g., `xcrun`), and package-manager locations. Discovery never mutates config by itself.

### Combined Flow

1. Built-in presets always appear in Settings > Code.
2. An availability resolver marks each as: **Available**, **Missing**, **Disabled**, **Custom Path**, **Broken**, or **Experimental**.
3. "Install" shows and optionally runs a package-manager command, only when the package manager itself is detected.
4. "Use existing" allows selecting a command/path for servers installed outside standard PATH locations.
5. User overrides layer over presets and can be reset to defaults.

### Critical Constraint: Availability/Launch Parity

Task #731 review surfaced a concrete bug: `xcrun --find sourcekit-lsp` can report "Available" in Settings while `WorkspaceLSPManager` launches via `/usr/bin/env sourcekit-lsp` which fails on xcrun-only installs. **A single resolver must produce the exact spawn command used at both detection time and launch time.** This parity requirement applies to all presets, not just Swift.

## Data Model

The current single-language registry model (`LanguageServerConfig` keyed by one language) should be replaced with a three-layer model:

### Layer 1: Built-in Presets (bundled, read-only)

```swift
struct LanguageServerPreset: Codable, Identifiable {
    var id: String                  // e.g. "typescript-language-server"
    var displayName: String
    var command: String
    var args: [String]
    var env: [String: String]
    var bindings: [LanguageBinding]
    var rootMarkers: [String]
    var installOptions: [InstallOption]
    var detection: [DetectionRule]
    var docsURL: String?
    var stability: Stability        // .stable, .experimental, .deprecated
}

struct LanguageBinding: Codable, Equatable {
    var languageId: String          // LSP language identifier
    var extensions: [String]        // file extensions
}
```

### Layer 2: User Overrides (persisted, sparse)

```swift
struct UserLanguageServerOverride: Codable, Identifiable {
    var id: String                  // matches preset id
    var enabled: Bool?
    var command: String?
    var args: [String]?
    var env: [String: String]?
    var bindings: [LanguageBinding]?
    var rootMarkers: [String]?
}
```

### Layer 3: Custom Servers (user-defined, full config)

```swift
struct CustomLanguageServer: Codable, Identifiable {
    var id: String
    var displayName: String
    var command: String
    var args: [String]
    var env: [String: String]
    var bindings: [LanguageBinding]
    var rootMarkers: [String]
    var enabled: Bool
}
```

The effective config is computed as: preset merged with override, plus any custom servers. This avoids duplicating the TS server into separate TS and JS entries while preserving correct `languageId` per opened document.

Migration from the existing `languageServers` dictionary is straightforward: each existing entry maps to either a preset override (if `id` matches) or a custom server.

## Settings > Code UX Proposal

### List View

Rows are grouped by language/server, not raw config entries. Each row shows:
- Server name and language badges
- Status badge: Available, Missing, Disabled, Custom Path, Broken, Experimental
- Toggle to enable/disable

### Row Actions

- **Enable/Disable** toggle
- **Install** button (when Missing and a package manager is detected)
- **Configure** to open detail panel
- **Test** to verify the server launches and responds

### Configure Panel

- Command/path field with "Browse" button
- Arguments editor
- Environment variables (advanced disclosure)
- File extensions and language bindings
- Root markers
- "Reset to preset defaults" action

### Install Experience

- Detect available package managers: Homebrew, npm, rustup
- Show the install command before executing
- If the required package manager is missing, show prerequisites
- After install, re-run detection and update status

### Test Connection

The test should mirror actual launch behavior exactly:
1. Resolve executable using the same resolver as `WorkspaceLSPManager`
2. Spawn with configured args and environment
3. Send LSP `initialize` request
4. Report success, or surface: stderr output, exit code, timeout

### Failure States

| Failure | Display |
|---|---|
| Command not found | "Server executable not found at {path}" with Install or Browse action |
| Path not executable | "File exists but is not executable" |
| Package manager missing | "Requires {brew/npm/rustup} — install it first" |
| Server starts then exits | Show stderr and exit code |
| Initialize timeout | "Server started but did not respond within {n}s" |
| Unsupported capability | "Server requires {capability} which Alas does not yet support" |

## Implementation Plan

1. **Fix availability/launch parity** — one resolver produces the exact spawn command used by `WorkspaceLSPManager`. This is a prerequisite for everything else and addresses the #731 review finding.
2. **Move availability checks off SwiftUI body** — cache async status in a view model or service. The current synchronous `xcrun` call can stall Settings.
3. **Introduce preset + binding model** — replace single-language registry with the three-layer model above. Migrate existing `languageServers` config.
4. **Seed presets** — Swift, Rust, TypeScript/JavaScript, JSON/JSONC, Markdown, Kotlin.
5. **Package-manager detection** — detect `brew`, `npm`, `rustup` on macOS. Design the detection interface to accept Linux package managers later.
6. **Validation/test connection API** — timeout, stderr capture, initialize handshake.
7. **Settings UI update** — implement the preset-aware list, configure panel, install flow, and test connection.
8. **Tests** — merge behavior, PATH/env-aware resolution, multi-binding lookup, install command selection, launch parity.

## Platform Considerations

The initial implementation targets macOS only. To avoid blocking future Linux support:

- Package-manager detection should be behind a protocol/interface, not hardcoded Homebrew paths.
- `xcrun` fallback is Swift-specific and macOS-only; guard it accordingly (already done in #731).
- PATH resolution should use the environment's actual PATH, not assume `/usr/local/bin` or `/opt/homebrew/bin`.
- Install commands in presets should be per-platform arrays, even if only macOS entries are populated initially.

## Risks

- **Kotlin LSP stability**: Pre-alpha, limited functionality. Mark as experimental; do not promise feature parity with IDE-based Kotlin support.
- **JSON package naming**: Binary name varies across npm package versions. Detection must try multiple names.
- **Markdown server choice**: Marksman is simpler but less feature-rich. Users expecting VS Code-level Markdown support may be disappointed. Consider noting this in the UI.
- **Availability/launch mismatch**: The #731 review already flagged this for Swift. The preset model must enforce parity by design, not by convention.
- **PATH vs env mismatch**: Current PATH lookup ignores `entry.env` while `LSPTransport` overlays it before launch. Custom configs with `PATH` in their env will show incorrect availability status until this is fixed.

## Sources

- rust-analyzer install documentation; rustup component list
- typescript-language-server README (npm)
- JetBrains kotlin-lsp README and Homebrew cask
- vscode-json-language-server and vscode-langservers-extracted (npm)
- Marksman Homebrew formula; markdown-oxide README
- Alas #731 code review findings (availability/launch parity, SwiftUI body rendering, env mismatch)
