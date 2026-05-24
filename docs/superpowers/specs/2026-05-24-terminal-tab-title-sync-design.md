# Terminal Tab Title Sync – Design

## Overview

Wire Ghostty's terminal title changes (OSC sequences emitted by shells / processes) into the visible tab bar label for terminal tabs. When the terminal reports a title, the active terminal tab's label updates to match. If the terminal never reports a title, the existing tab label (stable name, default "bash", or user rename) is preserved.

The feature is gated behind a new toggle in **Settings → Terminal → Appearance**: "Sync tab title with terminal title", defaulting to `false` for backward compatibility.

---

## Constraints & Decisions

- **Runtime-only.** Tab titles from the terminal are ephemeral display state. They are never persisted. App relaunch restores the original `TerminalTabState.title`.
- **Focused leaf wins.** A terminal tab may contain a split pane tree. The tab bar displays the title of whichever leaf currently has focus.
- **Empty title ignored.** Ghostty sometimes reports `""` on title reset. We ignore empty strings so the prior title (persistent or runtime) remains visible.
- **Manual rename takes control.** When a user manually renames a terminal tab ("Rename…" context menu), all runtime titles for that tab's leaves are cleared. The persistent title wins until future non-empty terminal title updates arrive.

---

## Architecture

### 1. TabsManager – ephemeral title store

TabsManager receives a new non-persisted property:

```swift
var terminalRuntimeTitles: [String: String] = [:]   // leafId → display title
```

New API added to `TabsManager`:

- `setTerminalRuntimeTitle(leafId:title:)` – stores a title for the given leaf id. Non-empty only.
- `clearTerminalRuntimeTitles(forLeavesInTabId:)` – removes all runtime title entries belonging to leaves of the specified tab.
- `displayTerminalTitle(for tab: Tab, in worktreeId: String) -> String?` – convenience that, given a `.terminal` tab, resolves the runtime title for its currently focused leaf, or `nil` if the feature is off / the leaf has no runtime title.

**Cleanup:** `close(worktreeId:tabId:)` now walks the closing terminal tab's leaves and removes their `terminalRuntimeTitles` entries.

### 2. TabBarView – display-time resolution

`TabButton` uses a resolved label instead of raw `tab.title`:

- Add a new prop `titleLookup: (TabID) -> String?` to `TabBarView`.
- Inside `TabButton`, compute: `let displayTitle = titleLookup(tab.id) ?? tab.title`
- The `Text(tab.title)` line is replaced with `Text(displayTitle)`.

`CenterPaneView` (the caller) provides a closure that, for a `.terminal` tab, asks `TabsManager.displayTerminalTitle(...)` for the focused-leaf runtime title; for all other tab kinds it returns `nil`.

### 3. TerminalTabView – wiring titleHandler

In `PaneLeafView.onAppear`, after the existing `wireCwdHandler` and `wireOpenURLHandler`, add:

```swift
private func wireTitleHandler(session: TerminalSession, leafId: String) {
    session.surface.titleHandler = { [weak state] title in
        guard let state, !title.isEmpty else { return }
        guard state.config.terminal.syncTabTitleWithTerminalTitle else { return }
        state.tabs.setTerminalRuntimeTitle(leafId: leafId, title: title)
    }
}
```

The handler is set once per leaf on view appear and survives pane focus changes.

### 4. Manual rename interaction

`AppState.renameTerminalTab(worktreeId:tabId:)` (the context-menu "Rename…" path) is updated so that after the alert returns and `tabs.renameTerminal(...)` mutates the persistent title, it also calls:

```swift
if let terminal = tabs.terminalState(for: tabId) {
    for leaf in terminal.root.leaves() {
        tabs.clearTerminalRuntimeTitles(forLeavesInTabId: tabId)
    }
}
```

This ensures the user's manually-chosen name is immediately visible.

---

## Config Model

In `AppConfig.Terminal`:

```swift
var syncTabTitleWithTerminalTitle: Bool
```

Default:

```swift
terminal: Terminal(
    ...
    syncTabTitleWithTerminalTitle: false
)
```

Decode path: graceful fallback to `false` for configs saved before this field was added.

---

## Settings UI

In `TerminalPane.swift`, under the existing `SettingsGroup(title: "Appearance")`, add a `SettingsRow` after the "Bell" row:

```swift
SettingsRow(name: "Sync tab title with terminal title",
            desc: "When the terminal reports a title, update the tab label.") {
    AlasToggle(on: state.bind(\.terminal.syncTabTitleWithTerminalTitle))
}
```

---

## Error Handling & Edge Cases

| Scenario | Behavior |
|---|---|
| Toggle is off | Runtime title dictionary stays empty; display falls through to persistent `tab.title` |
| Terminal reports `""` | Ignored; prior title remains |
| Tab closed | Cleanup removes leaf entries from `terminalRuntimeTitles` |
| Split pane; focus switches | Tab bar label updates to the focused leaf's runtime title automatically |
| Non-terminal tab | `titleLookup` returns `nil`; persistent title is shown unchanged |
| App relaunch | Runtime dictionary is empty; all tabs restore with their persistent titles |

---

## Testing Plan

1. **Happy path:** open terminal, simulate `titleHandler("vim foo")` via a test harness; assert `TabsManager.terminalRuntimeTitles` contains the leaf id and the tab bar displays "vim foo".
2. **Empty title ignored:** call handler with `""`; assert no change in display title.
3. **Manual rename clears runtime:** set a runtime title, trigger `renameTerminalTab`, assert runtime title entry is gone and persistent title is visible.
4. **Toggle off:** set runtime title with toggle enabled, then disable toggle (or start disabled), assert display falls through to persistent title.
5. **Split pane focused leaf:** two leaves with different runtime titles; assert focused-leaf title is shown.
6. **Tab close cleanup:** close tab, assert `terminalRuntimeTitles` no longer contains leaf ids from that tab.
