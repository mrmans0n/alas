# Optional Close Tab Confirmation

## Goal

Add optional, disabled-by-default confirmation prompts before closing Terminal and Chat tabs. The feature protects users from accidental `Command-W` or tab close button actions without changing the default fast-close behavior.

## Settings Placement

Terminal and Chat confirmations are separate settings because they belong to different user workflows.

- `Settings -> Terminal -> Sessions`
  - Label: `Confirm before closing terminal tabs`
  - Description: `Ask before closing Terminal tabs with Command-W or the tab close button.`
  - Default: off

- `Settings -> Agents -> Chat`
  - Label: `Confirm before closing chat tabs`
  - Description: `Ask before closing Chat tabs with Command-W or the tab close button.`
  - Default: off

Use "Chat" in the UI instead of "ACP" to match the existing user-facing language in Settings.

## Behavior

The confirmation applies only to single-tab close requests for the matching tab type:

- Terminal tab close uses the Terminal setting.
- Chat tab close uses the Agents/Chat setting.
- Editor, diff, commit, image, markdown, and merge-conflict tabs keep their current behavior.
- `Command-W` and the tab close button use the same close-request path.

For split terminal tabs, the existing `Command-W` behavior remains: if the active terminal tab has multiple panes, `Command-W` closes the focused pane first. The terminal-tab confirmation applies only when the action would close the whole terminal tab.

Bulk tab actions keep their existing behavior for this feature:

- Close Other Tabs
- Close All Tabs
- Close Tabs to the Left
- Close Tabs to the Right
- Worktree archive/delete cleanup
- Process-exit cleanup
- Terminate All Terminal Sessions

Those flows either already have their own confirmation semantics or are cleanup operations rather than accidental single-tab close actions.

## Prompt Copy

Terminal tab prompt:

- Title: `Close terminal tab?`
- Message: `This will stop the terminal session and any running process in it.`
- Primary button: `Close Terminal`
- Cancel button: `Cancel`

Chat tab prompt:

- Title: `Close chat tab?`
- Message: `This will stop the chat session. The transcript remains available only if it has already been persisted.`
- Primary button: `Close Chat`
- Cancel button: `Cancel`

The prompts should be standard warning alerts or SwiftUI alerts consistent with nearby destructive confirmations.

## Data Model

Persist two booleans with backwards-compatible defaults:

- `AppConfig.Terminal.confirmCloseTabs = false`
- `AppConfig.Harness.confirmCloseChatTabs = false`

Older config files decode both as `false`.

## Testing

Add focused tests around the pure routing/policy where practical:

- Terminal confirmation is required only for terminal tabs when the terminal setting is enabled.
- Chat confirmation is required only for chat tabs when the chat setting is enabled.
- Non-terminal and non-chat tabs never use these settings.
- Missing settings in older config JSON decode to `false`.

Manual verification should cover:

- Toggling each setting in Settings.
- Closing Terminal and Chat tabs through `Command-W`.
- Closing Terminal and Chat tabs through the tab close button.
- Split terminal `Command-W` still closes a pane before prompting for tab close.
