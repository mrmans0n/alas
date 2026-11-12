# Devices: clipboard and text beyond ASCII

## Goal

Move text between the Mac and a simulator, and let agents type any text.
You get ⌘V and ⌘C on the simulator screen; agents get `device_type` that
handles any text, and a `device_clipboard` tool. Item B of the Devices
follow-ups (A logs, B clipboard and text, C small controls, D
settle-and-diff, E held calls for VMs).

## What exists, checked on iOS 26.5 / Xcode 26.6

Probed with a throwaway UIKit app whose focused text view logs its text, and
⌘V/⌘C sent as HID keys through `AlasSimulatorSession.key(usage:down:)`
(Command is usage 0xE3).

- Your keys reach the simulator through `DeviceScreenView`, but Command
  shortcuts stay with Alas: ⌘V over the screen does nothing for the
  simulator today.
- `device_type` sends HID key presses for ASCII on a US layout
  (`DeviceTextInput`) and refuses anything else with
  `device_type_unsupported`.
- `simctl pbcopy` and `simctl pbpaste` read and write the simulator's
  pasteboard. They need a GUI login session, which Alas always has.
- ⌘V sent as HID keys never pastes on its own: `pasted` logs "Paste requires
  user authorization. Prompting..." and the field stays empty. iOS doesn't
  count the simulator's key events as a user paste. Turning on the
  simulator's hardware keyboard
  (`-[SimDevice setHardwareKeyboardEnabled:keyboardType:error:]`) doesn't
  change that.
- After `simctl privacy <udid> grant pasteboard <bundle>`, every ⌘V pasted:
  "Café ☕️", the first ⌘V after launch, with the hardware keyboard on or
  off. Putting back the old pasteboard text and resetting the permission
  0, 50, 150 or 300 ms after the chord never lost a paste (2 runs).
- A grant takes 0.35–0.5 s. It didn't restart the running app (the test app
  and Safari kept their pids).
- The grant is a row in the simulator's
  `data/Library/TCC/TCC.db`, table `access`: `service =
  'kTCCServicePasteboard'`, `client = <bundle>`, `auth_value` 2 for allowed,
  0 for denied. `simctl privacy reset pasteboard <bundle>` deletes the row.
  `pasteboard` isn't in `simctl help privacy`, but `grant`, `revoke` and
  `reset` accept it.
- ⌘C needs no grant: with text selected, the selection reached `simctl
  pbpaste` about 0.5 s after the chord.
- serve-sim (upstream) pastes the same way, but for headless workers it
  writes through an in-simulator helper app and reads through a dylib
  injected into apps. Alas runs in your GUI session and needs neither.

## Decisions

- You: ⌘V pastes the Mac clipboard's text into the simulator; ⌘C copies the
  simulator's selection to the Mac clipboard.
- Agents: `device_type` types any text: ASCII runs as key presses, everything
  else pasted. `device_clipboard` reads or sets the simulator's pasteboard.
- Mixed text is split into runs, so `\n` stays a Return key and the field's
  per-key handlers still see typed characters.
- After an agent's paste, the pasteboard gets its old text back.
- Before each paste, the app in front is granted pasteboard access, and
  right after, its previous permission is put back, read from `TCC.db`, so
  the app's own "Allow Paste" prompt still shows in your testing.

## 1. Pasting

`SimulatorPasteboard` in AlasCore does one paste session at a time per
simulator:

1. Take the simulator's pasteboard lock. Your pastes and copies and agents'
   pastes all take it, so a restore can't overwrite text that another paste
   is about to use.
2. Find the app in front (`SimulatorForeground` from item A, the accessibility
   bridge as the fallback). With no app in front, for example in the home
   screen's search, paste without a grant.
3. Read the app's pasteboard row in `TCC.db`. If it isn't allowed already,
   `simctl privacy grant pasteboard <bundle>`.
4. For an agent, read the old text with `pbpaste`.
5. For each run to paste: `pbcopy` the run, then send ⌘V: Command down, V
   down, V up, Command up, 20 ms apart, as `device_type` spaces its keys.
6. Restore, also after a failure, takeover or cancel: an agent's old text
   with `pbcopy` (skipped when it was empty: `pbpaste` can't tell empty text
   from an image, and writing "" would erase the image); then the
   permission: no row before → `reset`; denied before → `revoke`; allowed
   before → nothing. A row with any other value counts as no row.
7. Release the lock.

A restore that fails is logged and doesn't fail the call: the text did get
pasted.

## 2. Agents

### `device_type`

- `DeviceTextInput.runs(for:)` splits text into `.keys([Press])` and
  `.paste(String)` runs. A character is typed when the US layout has it,
  as today, including `\n`, `\r\n` and `\t`. Each stretch of consecutive
  other characters is one paste run; a space between two of them joins the
  run, so "日本 語" is one paste. For "Café au lait\n" that's keys "Caf",
  paste "é", keys " au lait" and Return.
- Key runs work as today, with the takeover and cancel checks between keys.
  The first paste run opens the paste session (steps 1–4), and each later
  run reuses it; the session is restored once when the call ends.
- `device_type_unsupported` goes away. The text limit stays 4096 bytes.
- Tool description: "Type text into the focused field of the simulator.
  ASCII is typed as key presses on a US keyboard, and \n presses Return;
  other characters, such as accents and emoji, are pasted. Tap the field
  first." The preamble sentence about `device_type` says the same.

### `device_clipboard`

| Argument | Default | Limits |
|---|---|---|
| `udid` | required | |
| `text` | none | ≤ 65536 bytes |

- Without `text`: returns `{"text": "<pbpaste>"}`. Read-only: not held while
  you drive, takes no input turn.
- With `text`: writes it with `pbcopy` and returns `{"ok": true}`. Held while
  you drive, like the settings tools. It changes no permission.
- Errors: `device_not_booted`; `device_clipboard_failed: <simctl's message>`.
- Description: "Read the simulator's pasteboard, or set it by passing text.
  To paste it into a field, tap the field and type with device_type, or use
  the app's Paste menu."

## 3. You

- `DeviceScreenView` implements the `copy(_:)` and `paste(_:)` responder
  actions, so Edit › Copy and Edit › Paste, and ⌘C and ⌘V, reach the
  simulator while the screen has focus. Other Command shortcuts stay with
  Alas. `validateMenuItem` disables both while an agent drives or the screen
  ignores input.
- ⌘V: takes `NSPasteboard.general`'s string. Without one, the screen shows
  "The clipboard has no text to paste." Over 1 MB, it shows "That text is too
  long to paste." Otherwise it pastes as in section 1, with steps 4 and 6's
  text restore skipped: the text stays on the simulator's pasteboard, like
  Simulator.app's pasteboard sync.
- ⌘C: under the pasteboard lock, notes `pbpaste`, sends ⌘C, and polls
  `pbpaste` every 100 ms for up to 2 s. When it changes, the text goes on
  the Mac clipboard and the screen shows "Copied". Otherwise it shows
  "Nothing was copied. Select some text first." Copying the text the
  pasteboard already holds ends up here too; telling the two apart would
  need an in-simulator helper.
- Messages use the pill at the bottom of the screen that install progress
  uses (`DevicePaneModel`), and disappear after 2 s. Your pastes and copies
  on one simulator run one after another.

## Code

- AlasCore (`AlasFeatures/Devices`):
  - `DeviceTextInput.runs(for:)` replacing `presses(for:)`'s failure case.
  - `SimulatorPasteboard.swift`: `SimulatorPasteAccess` (the previous
    `TCC.db` state and the restore it needs), reading the row with
    `SQLiteDatabase`; `SimulatorControl.pbcopy/pbpaste/pasteboardAccess`;
    a `SimulatorPasteboardControl` protocol and its live implementation
    with the per-simulator lock.
  - `DeviceCommand.clipboard(udid:text:)`, decoded in `AlasCLIRequest`.
- App:
  - `DeviceAgentControl` gets a `pasteboard:` dependency, the paste runs in
    `.type`, and `.clipboard`.
  - `DeviceScreenView` responder actions; `DevicePaneModel` runs your
    pastes and copies and owns the pill message.
- Rust: the `device_clipboard` definition, parsing, request and tool lists;
  the new `device_type` description.

## Testing

- AlasCore: `DeviceTextInputTests` for run splitting (parameterized: ASCII
  only, accents, emoji, line breaks around non-ASCII, a paste run at each
  end); `SimulatorPasteAccess` for the restore per previous state, and
  reading the row from a fixture `TCC.db`; `DeviceCommandTests` rows for
  `device_clipboard`.
- App `DeviceAgentControlTests` with a fake pasteboard: mixed text sends keys
  and pastes in order and restores once; a takeover in the middle still
  restores; `device_clipboard` read isn't held during a takeover and write
  is.
- Rust: parsing, refusals, tool lists, read-only annotation.
- Not tested: the responder actions and the simctl plumbing. A throwaway
  end-to-end run with the test field app (agent paste with restore, your
  paste and copy, the TCC row before and after), then your manual pass.

## Docs

- `docs/devices.md`: copy and paste on the screen; `device_clipboard` in the
  tool table; `device_type` typing any text.
- Tick "Clipboard both ways" in `docs/plans/2026-11-04-device-panel-design.md`.
