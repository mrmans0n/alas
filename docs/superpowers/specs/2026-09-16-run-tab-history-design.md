# Run Tab History Design

## Goal

Make the Run tab useful after a command completes. The tab will keep runnable scripts at the top, show durable completed-run history below them, use the Agents tab's inset card interaction language, and open a selected run's output as a center-pane report.

## Scope

- Persist completed run history across Alas relaunches.
- Retain at most 100 completed runs per worktree.
- Store the final 1 MiB of plain-text output for every observed outcome.
- Page history 20 entries at a time.
- Clear completed history for the visible worktree only.
- Replace the current edge-to-edge Run row hover treatment with shared Agents-style card chrome.

Out of scope: per-entry deletion, project-wide clear, search/filtering, configurable retention, and a new screenshot-test framework.

## Constraints and decisions

| Concern | Decision |
| --- | --- |
| Durable storage | SQLite under `Paths.appSupportRoot/run-history.sqlite` |
| Live command state | Keep `RunRecordStore` synchronous and in-memory |
| Retention | 100 completed records per worktree; prune oldest in the append transaction |
| Output | Final 1 MiB for success, failure, stopped, and unknown outcomes; record truncation and unavailability honestly |
| History UI | Compact newest-first report rows, 20 per page |
| Report UI | Restorable center tab, not an inline rail expansion or a modal sheet |
| Clear scope | Current worktree's completed runs only; active runs remain intact |

## Architecture

### Live state remains separate

`RunRecordStore` remains the source for a script's current/latest observed lifecycle. Its synchronous interface continues to claim a launch slot before a terminal opens, reject stale completion callbacks, resolve active port ownership, and reconcile a disappeared terminal. Database I/O never enters this path.

### Durable history store

Add `RunHistoryStore`, an actor backed by the existing `SQLiteDatabase` module. Its interface is intentionally small:

- append an immutable completed `RunHistoryEntry`;
- fetch a newest-first page and total count for a worktree;
- fetch one entry, including output, by run ID;
- clear a worktree's completed entries;
- purge a deleted worktree.

`RunHistoryEntry` snapshots run ID, script key/name, worktree ID, branch, execution target, endpoint, outcome/exit code, start/end time, duration, port-conflict context, output availability/text, and truncation state. Output is omitted from page queries and fetched only for a report.

The run ID is unique at the database level. Appending and pruning execute in one transaction, retaining the newest 100 records in that worktree. Database errors are reported through the existing application error path and never change a command's observed result.

### Durable reports as center tabs

Add `RunReportTabState` and `Tab.runReport`, identified by `run-report:<runID>`. Opening the same history item focuses its existing report tab. The tab is Codable/restorable and lazily loads its entry from `RunHistoryStore`; a cleared or pruned entry displays an ordinary unavailable state.

`RunReportTabView` presents script name, outcome, branch, execution target, start/end time, duration, selectable monospaced output, Copy Output, and a truncation or unavailable-output notice.

The current failure-only output sheet is removed. Failure notifications and attention jumps route to the durable report tab. Notification state retains identifiers and metadata rather than duplicate output.

### Shared right-pane card chrome

Extract the existing Agents card surface into a reusable right-pane module. It owns the inset rounded shape, state-tinted gradient, border, shadow, hover, and selected variants. Agents adopt the shared module without visual change; Run uses it rather than duplicating values.

## Lifecycle and data flow

1. A launch claims the current `RunRecordStore` slot synchronously. A failure before the command exists rolls the claim back and writes no history.
2. `RunScriptCompletionMonitor` captures the final 1 MiB for every completed local or remote command, not only failures. It marks beginning truncation.
3. Every finish, stop, or lost-observation transition returns its finalized record only when it actually settles an active run. AppState turns it into one immutable history entry and appends it. Late or superseded callbacks return no entry.
4. On normal completion, the live row updates immediately. The durable append occurs off the main actor. A successful append advances a history revision that refreshes page one; if the user was on an older page, it resets to page one so content does not shift beneath them.
5. Stop, restart, lost observation, and graceful termination capture a best-effort partial transcript before capture files are removed. If output cannot be read, the run still archives with output marked unavailable. A crash may lose an active run, but Alas never fabricates an outcome.
6. App termination awaits pending history writes. Worktree deletion purges its history through the same store path.
7. Clear History confirms destructive deletion for the current worktree, closes that worktree's report tabs, deletes completed records in one transaction, and resets the list to page one. Active records are untouched.

## Run tab behavior

### Runnable scripts

Repo and Global groups remain, but use inset Agents-style headers and 10-point rail padding rather than edge-to-edge bands. Rows become cards with 8-point spacing. Status, endpoint, terminal, Run/Stop/Restart, and Edit controls keep their existing semantics. The card itself does not add a competing click action.

### History

A History header follows all runnable groups. It has the total count and a trailing `Clear…` action. Each compact row shows:

- status dot and script name;
- relative completion time;
- outcome and exit code when relevant;
- duration;
- branch.

The row is a native plain `Button` that opens its report. Hover and active-report selection use the shared inset card chrome; no state paints to the rail edge. The initial page contains the newest 20 records. The footer reads `1–20 of 84` and exposes labeled Previous/Next buttons with correct disabled states. New completion resets the list to page one. Empty history keeps the section visible and says: `Completed runs will appear here.`

`Clear…` opens a destructive confirmation that names the visible worktree and completed-record count. There is no per-entry removal or project-wide variant.

## Accessibility

- History identity is the stable run ID.
- Row buttons expose a combined label with script, result, duration, and completion time, plus selected state when their report is active.
- Status dots are decorative.
- Clear and page controls have explicit labels and disabled states.
- Native Buttons and center tabs provide normal keyboard focus behavior.

## Error handling

| Condition | Behavior |
| --- | --- |
| Transcript unavailable | Archive metadata; report says `Output unavailable.` |
| Transcript truncated | Archive final 1 MiB; report says `Output truncated to the final 1 MiB.` |
| Monitor/remote connection failure | Settle as unknown; do not claim success |
| History DB error | Preserve live outcome, show compact retry state in History, report error through existing application handling |
| Missing cleared/pruned report | Show unavailable content in the restored/open report tab |
| Duplicate/late completion | Ignore after the first active-to-finished transition |

## Verification

### Swift Testing

- `RunHistoryStoreTests`: persistence across reopening, newest-first 20-row paging and totals, worktree-isolated clear/purge, 100-entry cap, duplicate ID defense, output/truncation lookup.
- `RunScriptCompletionMonitorTests`: capture success and failure output locally and remotely, final-1-MiB cap, decoding-safe boundaries, honest partial/unavailable stop and unknown output.
- `RunRecordStoreTests` and `AppStateRunRecordTests`: exactly-once settlement, stop precedence, superseded-callback suppression, no history on launch failure, all outcome snapshots, clear leaves active work untouched.
- `RunHistoryPresentationTests`: status/metadata formatting, page controls, clear availability, and empty state.
- Existing center-tab tests: `RunReportTabState` Codable round-trip, stable open-or-focus identity, and worktree-scoped report-tab closure.

### Real-surface proof

1. Run `xcodegen`.
2. Build with the required macOS `xcodebuild` command.
3. Launch Alas with scripts that succeed, fail, stop, and emit more than 1 MiB.
4. Verify Agents-style inset hover/selection, page navigation, center reports, copy output, truncation disclosure, and clear-without-stopping an active run.
5. Relaunch Alas and verify durable history and report tabs reload.
6. Run the required macOS test suite.
