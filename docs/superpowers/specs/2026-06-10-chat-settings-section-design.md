# Settings Chat Section Design

## Summary

Add a first-class `Settings > Chat` section and move chat-specific preferences
out of `Settings > Agents`. The change is a UI organization pass: existing
config storage remains unchanged so user preferences survive without a
migration.

## Goals

- Add `Chat` as its own item in the Settings sidebar.
- Keep `Agents` focused on agent registry, custom agents, and worktree
  auto-launch behavior.
- Move all current chat-specific settings into the new Chat pane.
- Keep terminal harness notifications and hook installation under
  `Settings > Terminal`.
- Avoid persisted config key renames or migration work.

## Non-Goals

- No changes to ACP chat runtime behavior.
- No changes to terminal settings, harness notifications, or hook installers.
- No new chat settings beyond relocating existing controls.
- No cross-link or placeholder row left behind in `Settings > Agents`.

## UI Structure

Add `SettingsSection.chat` with label `Chat` and a chat-oriented icon. The
existing Settings sidebar ordering should remain alphabetic for non-debug
sections, with `Debug` last when visible.

Add a new `ChatPane` under `Alas/Sources/Settings`. It should follow the
existing pane pattern: title, short subtitle, then `SettingsGroup` sections with
`SettingsRow` controls.

The new pane contains these groups:

### Appearance

- `Font family`
  - Uses `FontFamilyPicker`.
  - Binds to `state.config.agents.chatFontFamily`.
- `Font size`
  - Uses the same numeric `AlasField` pattern as Terminal and Code settings.
  - Binds to `state.config.agents.chatFontSize`.
  - Clamps writes to `8...64`.

These fields exist in the chat typography work from PR #502. If the current
branch does not yet contain those config keys, implementation should bring that
work in or rebase onto it before wiring the pane.

### Launcher

- `Default launch surface`
  - Uses the existing Terminal/Chat picker.
  - Binds to `state.config.agents.defaultLauncherMode`.
  - This belongs in Chat because it controls whether the `Option-Command-T`
    launcher starts on Terminal or Chat.

### Composer

- `While busy, Return queues; Option-Return steers`
  - Reuses the current label and behavior.
  - Binds to `state.config.harness.acpSendOnEnter`.

### Sessions

- `Confirm before closing chat tabs`
  - Binds to `state.config.harness.confirmCloseChatTabs`.
- `Auto-run`
  - Binds to `state.config.harness.acpAutoRunByDefault`.

## Agents Pane Changes

Remove the current `Launcher (Option-Command-T)` group and the current `Chat`
group from `AgentsPane`.

Keep the existing:

- available agents grid
- `Worktree auto-launch` group
- `Harness` group linking to Terminal settings

Do not add an `Open Chat Settings` row or any replacement anchor in `Agents`.

## Data Model

Do not introduce a new `AppConfig.Chat` model in this change. Existing fields
stay where they are:

- `agents.defaultLauncherMode`
- `agents.chatFontFamily`
- `agents.chatFontSize`
- `harness.acpSendOnEnter`
- `harness.confirmCloseChatTabs`
- `harness.acpAutoRunByDefault`

This keeps the change compatible with existing config files and avoids
unnecessary JSON churn.

## Testing

Update `SettingsSectionTests` so the sidebar sections include `Chat` and remain
alphabetic except `Debug` last.

Add a `ChatPane` smoke test similar to the existing settings pane tests. The
test should instantiate `ChatPane` with an `AppState`, inject the current theme,
and verify it lays out without crashing.

If implementation touches chat font config availability, preserve or add tests
for:

- default chat font values
- backward-compatible decode when older config lacks chat font fields
- font size clamping on decode

## Verification

Before finishing implementation, run the project-standard checks:

```bash
xcodegen
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' -quiet build
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' test
```
