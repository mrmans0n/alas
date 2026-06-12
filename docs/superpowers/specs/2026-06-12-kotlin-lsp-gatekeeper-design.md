# Kotlin LSP Gatekeeper Helper Remediation Design

## Context

Alas already has a built-in Kotlin language server configuration:

- language: `kotlin`
- extensions: `kt`, `kts`
- command: `kotlin-lsp`
- args: `--stdio`

Before spawning a language server, Alas checks whether the configured executable is blocked by macOS Gatekeeper. The check is based on the executable's `com.apple.quarantine` extended attribute and feeds the existing blocked-language-server banner and `GatekeeperRemediator`.

JetBrains' `kotlin-lsp` can spawn a helper executable named `intellij-server`. When that helper is quarantined, macOS shows a blocking "`intellij-server` Not Opened" dialog even though Alas already considered `kotlin-lsp` available. The user cannot remediate this from the current Alas prompt because the blocked executable is not the configured top-level command.

## Goal

Opening a Kotlin file should work out of the box when `kotlin-lsp` is installed. Alas should preflight and, when possible, automatically remove quarantine from the Kotlin helper before launching the language server.

If automatic remediation fails, Alas should fall back to the existing inline blocked-language-server banner, pointing at the actual blocked helper path.

## Non-Goals

- Replace JetBrains `kotlin-lsp` with another Kotlin language server.
- Add a Kotlin installer for GitHub release assets.
- Build a generic child-process failure detector based on stderr or process exit behavior.
- Add visible Settings UI for editing helper commands in this iteration.

## Proposed Approach

Extend `LanguageServerConfig` with optional helper executable metadata named `gatekeeperHelpers: [String]`.

The Kotlin built-in config will keep launching `kotlin-lsp --stdio` and add `intellij-server` as a Gatekeeper helper. The helper should be resolved using the same effective PATH and per-entry environment as the primary command.

`LanguageServerAvailability` will treat a language server as available only when:

1. The primary command resolves and is not blocked.
2. Every configured helper that resolves is not blocked, or can be automatically remediated.

If a helper cannot be remediated, availability returns `.blockedByGatekeeper(realPath:)` for that helper path. Existing notification and banner code can then reuse the current remediation UI.

## Data Flow

1. `WorkspaceLSPManager.openDocument` resolves the registry entry for `kotlin`.
2. Availability resolves `kotlin-lsp`, checks its Gatekeeper state, and auto-remediates if needed.
3. Availability resolves `intellij-server`, checks its Gatekeeper state, and auto-remediates if needed.
4. If both are allowed, `WorkspaceLSPManager` launches `kotlin-lsp --stdio`.
5. If either path remains blocked, `WorkspaceLSPManager` posts `.lspBlockedByGatekeeper` with the blocked real path and does not launch.
6. The existing blocked nudge can still offer one-click remediation and reopen Kotlin documents after success.

## Compatibility

Existing persisted language-server configs should decode with an empty helper list. User-defined Kotlin configs can continue to override the built-in Kotlin entry completely.

The Settings Code pane does not need new controls initially. Helper metadata is a built-in/runtime concern for known server launchers, not a common user-facing configuration field.

## Error Handling

If a helper cannot be found, availability should not mark the server unavailable. Some launchers may embed helpers in version-specific locations or unpack them lazily. The helper preflight should only block when it resolves a concrete executable path and that path is quarantined.

If quarantine removal fails or reassessment still rejects the executable, availability should return `.blockedByGatekeeper(realPath:)` for that helper. The existing banner can show the user a manual retry path.

If Gatekeeper assessment errors, keep the existing fail-open behavior: return available rather than hiding a runnable server behind a false block.

## Testing

Add Swift Testing coverage for:

- Decoding older `LanguageServerConfig` JSON without helper metadata.
- Kotlin built-in config including `intellij-server` as a helper.
- Availability checking helper paths after the primary command resolves.
- Successful auto-remediation turning a quarantined helper into available status.
- Failed auto-remediation returning `.blockedByGatekeeper` for the helper real path.
- Missing helper command not causing `.notInstalled`.

No new UI test is required because the fallback banner path already exists and remains unchanged.
