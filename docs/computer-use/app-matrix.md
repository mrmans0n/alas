# Computer use: app matrix

Results of the manual app-by-app pass over the Computer use tools (`computer_apps`, `computer_screenshot`, `computer_inspect`, `computer_click`, `computer_type`, `computer_key`, `computer_scroll`, `computer_drag`, `computer_open_app`, `computer_wait`). Each cell is the final state after all fixes from the pass. Use it as a regression checklist when touching input, clipboard, approval or window-enumeration code.

## When and how it was checked

- Dates: 2026-10-24 (first pass and re-checks) and 2026-10-25 (last re-checks).
- Hardware: one built-in display. No external display was connected.
- Window manager: AeroSpace (see "Window manager notes").
- Builds: the first passes ran against Alas Dev (`io.nlopez.alas.dev`, a Debug build); the later passes ran against the release build. Both were launched with `ALAS_APP_SUPPORT_DIR` pointing at a scratch directory so they did not touch the real Application Support data.
- Start a new agent session after rebuilding. ACP sessions keep the `alas mcp` server process they started with, and it survives app relaunches. An old session therefore runs the old tool behavior (for example, an old default depth for `computer_inspect` queries) against a new app.
- Every target app was tested while behind another app, which is the normal situation for an agent.

## Matrix

PASS means it worked on the final build. "via AX" means the tool reports `delivery: "ax"` instead of a posted event. NOT CHECKED means no live check was done; it does not mean it is known to work.

| App | inspect | click by ref | click by x/y | type | key | scroll | drag | open_app | cursor | stop shortcut |
|---|---|---|---|---|---|---|---|---|---|---|
| TextEdit | PASS | PASS (parked window: via AX) | PASS | PASS (parked window: AX only, otherwise refused) | PASS (cmd+a via Edit menu; Save sheet: escape presses Cancelar) | PASS | NOT CHECKED | PASS | NOT CHECKED | PASS |
| Finder | PASS | PASS | PASS | NOT CHECKED | PASS | PASS | PASS (same window, cross-window, parked windows; file moved on disk; result elements fresh) | PASS | NOT CHECKED | PASS |
| Safari | PASS | NOT CHECKED | PASS (`delivery: "background"`, links open; also with Alas on top) | NOT CHECKED | NOT CHECKED | NOT CHECKED | N/A | NOT CHECKED | NOT CHECKED | PASS |
| Chrome | NOT CHECKED (first-contact wake implemented) | NOT CHECKED | NOT CHECKED | NOT CHECKED | NOT CHECKED | NOT CHECKED | N/A | NOT CHECKED | NOT CHECKED | NOT CHECKED |
| Slack (Electron) | PASS (first read waits for the web area; depth-17 field found; query reads 32 levels) | PASS | NOT CHECKED | PASS (insert after cmd+a leaves the right value) | NOT CHECKED | NOT CHECKED | N/A | PASS | NOT CHECKED | PASS |
| Xcode | PASS (Source Editor found by query, `truncated: false`) | PASS (Open panel press returns a "didn't answer in time" warning) | NOT CHECKED | NOT CHECKED | NOT CHECKED | NOT CHECKED | N/A | PASS (first call returns `computer_approval_pending`) | cursor overlay cannot draw above layer-8 panels | PASS |
| Terminal | NOT CHECKED | NOT CHECKED | NOT CHECKED | NOT CHECKED | NOT CHECKED | NOT CHECKED | N/A | NOT CHECKED | NOT CHECKED | PASS (also with Secure Keyboard Entry on) |
| System Settings | PASS (sheets appear in the parent's tree) | PASS | PASS (via AX, on screen and parked) | NOT CHECKED | PASS (via AX: escape/return press Cancelar/Aceptar on a pane sheet, even parked) | PASS (via AX, on screen and parked) | N/A | NOT CHECKED | NOT CHECKED | PASS |
| 1Password, Keychain Access, credential prompts | blocked: `computer_blocked`, no windows listed | blocked | blocked | blocked | blocked | blocked | blocked | blocked (`computer_blocked`) | N/A | N/A (the agent can't act on these apps) |

Notes on the last row:

- 1Password, its browser helper and Keychain Access are listed in `computer_apps` as `blocked` with no windows, including when they run as accessory (menu-bar) apps.
- A system password prompt (for example the Users & Groups unlock prompt) is a LocalAuthentication view drawn inside the requesting app's own window. While one shows, the whole hosting app is marked `credential_prompt: true` with `windows: []`, and screenshot, inspect, click and type all return `computer_blocked: A system password prompt is showing in <App>; ask the user to answer it.` Everything works again once the user answers or cancels.
- A keychain prompt shows up as `coreautha` (layer 1000), `blocked`, with no windows.

## Window manager notes (AeroSpace)

- AeroSpace parks windows of hidden workspaces off screen at the bottom-right of the display (frames around x=1727, y=1065). `computer_apps` marks them with `off_screen: true`.
- With one display, an x/y point on a parked window is not on any display, so no posted event can land in any app. Many early "remote pane ignores clicks" failures were this, not extension-hosted content.
- Off-screen behavior: x/y click and scroll use AX at the point and refuse with an off-screen message when nothing there is pressable or scrollable. Typing is AX only. A key that cannot go through AX (a sheet button or menu item) returns the off-screen error rather than a background key reported as success. By-ref actions work through AX.
- Drags activate the app first, which makes AeroSpace bring the window back, then re-resolve element frames and raise the source window before checking the drop point.
- Setting `AXEnhancedUserInterface` on an app breaks window managers like AeroSpace, so Alas only sets it as a last resort on Chromium apps and restores it afterwards (see below).

## Known limitations

- x/y on plain text inside an off-screen row group fails with the off-screen error, because there is no AX element to press there. Use an element ref.
- Copy drags (with a modifier) wait 1.5 s before reporting.
- Chrome may get `AXEnhancedUserInterface` set briefly, only if `AXManualAccessibility` plus a re-read still shows no web area. Alas restores it to false at stop, turn end and session end. If Alas quits mid-turn, or a second session ends first, the flag can stay on or be cleared early.
- A credential prompt blocks the whole hosting app, not just the prompt, until the user answers it.
- Direct paste (`delivery: "direct"`) only happens for a single plain-text clipboard item or an empty clipboard. Anything else (files, images, rich text, several items) is typed, because restoring those proved lossy.
- Untitled windows that exactly match an `AXSheet` frame in the same app are hidden from `computer_apps`. The sheet is reached through its parent window. Titled Save/Open panels stay listed.
- Sheet buttons for escape/return are resolved by attribute, then identifier (`AX_CANCEL`/`AX_OK`), then title, then description. On a sheet whose default button attribute is empty, Return may press an OK button.
- A press that opens a modal panel can block, so the result carries a "didn't answer in time" warning even though the panel opened.
- 1Password and similar blocked apps cannot be opened or inspected by design.
- The cursor overlay cannot draw above layer-8 modal panels.

## Still to verify manually

- Drop window lists a newly dropped file after a cross-window drag. Covered by tests; the live re-run is pending.
- Approval Dock bounce repeats after 10 s while a request is still pending and Alas is not active. The first bounce and the "Waiting for approval: <App> - Show" menu item were confirmed; the re-bounce was not.
- Chrome first-contact behavior with AeroSpace: the first inspect returns web content, and window moves stay normal when `AXEnhancedUserInterface` is toggled.
- The apps and tools marked NOT CHECKED in the matrix.
