# Devices: settle and diff after agent actions

## Goal

After an agent taps, swipes, types or presses a button on a simulator, tell
it what changed on the screen, so it doesn't need a `device_snapshot` after
every step. Item D of the Devices follow-ups (A logs, B clipboard and text,
C small controls, D settle-and-diff, E held calls for VMs).

## What exists, checked on iOS 26.5 / Xcode 26.6

- Input actions (`device_tap`, `device_swipe`, `device_type`,
  `device_button`, `device_launch`, `device_open_url`, `device_rotate`)
  return `ok` or a small JSON, plus a screenshot with `include_screenshot`
  (300 ms after the action).
- `device_snapshot` reads the accessibility tree through AlasSimService.
  Measured on an iPhone 17, five reads each: a simple app 0.40–0.50 s,
  Safari 0.77–0.84 s, Settings 0.88–1.85 s.
- Refs are `s<generation>e<index>` and valid until the device's next
  snapshot. `DeviceSnapshot` keeps elements with role, label, value, id,
  frame and enabled.
- The vendored capture sends a frame when the framebuffer's seed changes,
  and repeats the last one at 5 fps when nothing changes. The app gets
  copies from a pool, so it can't use the seed; it can compare pixels.
- `computer_*` actions read the window back after a fixed 300 ms and return
  the elements; there is no diffing to reuse.

- End-to-end on an iPhone 17: a tap that navigates in Settings returned the
  new screen in about 2 s (settling plus a 1 s snapshot); typing into a
  text view with the software keyboard up returned the whole screen,
  because the keyboard's keys relabel (Q → q, suggestions) and fewer than
  half of the elements match.

## Decisions

- Settle-and-diff runs by default after input actions; `diff: false` skips
  it.
- Settling uses frames, not repeated accessibility reads.
- Matched elements keep their refs, so the agent's refs stay valid.

## 1. Settle

`DeviceFrameFingerprint` (app): about 4,096 luma samples on a grid across
the frame's first plane (`420v`), read from the IOSurface with it locked
read-only.

- Two fingerprints are the same when fewer than 0.5% of samples differ by
  more than 8 (out of 255). A blinking caret stays under that.
- After an action, Alas fingerprints each new frame. The screen is settled
  once the fingerprint has stayed the same for 300 ms. It gives up after 3 s
  and goes on, with `"settled": false` in the reply.
- Frames arrive at least every 200 ms (the 5 fps idle repeat), so 300 ms of
  sameness spans at least one repeat.
- `device_rotate` first waits for the new orientation, as it does today, then
  settles.

## 2. Diff

`DeviceSnapshotDiff` (AlasCore) compares the agent's previous snapshot of the
device with the new one:

- **Matching.** Elements match by `(role, id, label)`. Among elements with
  the same key, they pair in screen order (top to bottom, then left to
  right). Frames and values don't affect matching, so scrolling and edits
  pair up.
- **Refs.** A matched element keeps its previous ref. An unmatched new
  element keeps the new snapshot's ref. The stored snapshot is the new one
  with these refs, so `device_tap` by ref resolves against current frames.
  Refs stay unique because new refs carry the new generation.
- **Changes.** For matched elements, `value` and `enabled` are compared
  (`label` is part of the key, so it can't differ): `changed` lists
  `{ref, field, from, to}` with `field` `value` or `enabled`.
- **New screen.** When fewer than half of the new elements match, the reply
  is the full screen instead: `{"screen_changed": true, "screen": …,
  "elements": [...]}`, the same element JSON as `device_snapshot`. Also when
  there was no previous snapshot of the device.
- **Otherwise:** `{"settled": true, "added": [...], "removed": [...],
  "changed": [...]}`. `added` uses the snapshot element JSON; `removed` is
  `{ref, role, label}`. Each list keeps at most 200 entries, and
  `truncated: true` says some were left out.
- **Empty diff:** `added`, `removed` and `changed` are all empty. The reply
  stays the same shape; the tool description says an empty diff can mean
  the action had no visible effect.

## 3. In `DeviceAgentControl`

- Input actions get a `diff` argument (default true). After the action:
  settle, take a snapshot (a new generation), diff it against
  `snapshots[udid]`, store the result, and merge the diff JSON into the
  reply. `device_rotate` merges it next to `device` and `interface`.
  `device_launch` merges it next to `pid`.
- `include_screenshot` still works and is taken after settling.
- A snapshot failure after the input landed doesn't fail the action: the
  reply gets `"diff_error": "<message>"`.
- The user taking over during the settle stops it: the input already landed,
  so the reply is `ok` with `"diff_error": "The user took over."`.
- `diff: false` keeps today's reply.

## 4. Tools and preamble

- Rust: `diff` (boolean, default true) on the seven tools, a sentence in each
  description: "Returns what changed on the screen once it settles: added
  and removed elements with refs, and changed values; or the whole screen
  when it changed completely. Pass diff: false to skip that."
- Preamble: "Device actions return what changed on the screen, and refs you
  hold stay valid while their element is on screen; call device_snapshot
  only when you need the whole screen."

## Code

- AlasCore: `DeviceSnapshotDiff` next to `DeviceSnapshot`;
  `DeviceSnapshot` gains `withRefs(_:)` (or an init taking elements) so the
  stored snapshot carries the carried-over refs; `DeviceCommand` gains a
  `diff: Bool` on the seven actions (decoded, default true).
- App: `DeviceFrameFingerprint`; `DeviceAgentControl` settle and diff;
  `DeviceInput` unchanged (frames come through `subscribe`).
- Rust: arguments, descriptions, request fields, tests.

## Testing

- AlasCore `DeviceSnapshotDiff`: parameterized cases for added, removed,
  value changed, enabled changed, scrolled (frames moved, no changes),
  duplicate labels paired in order, the new-screen threshold, no previous
  snapshot, truncation, and refs carried over.
- App: `DeviceFrameFingerprint` on synthetic IOSurfaces (same, caret-sized
  change, real change); `DeviceAgentControlTests`: a tap returns the diff
  and a later tap by a carried-over ref lands on the element's new frame;
  `diff: false` keeps `ok`; a snapshot failure gives `diff_error`; settling
  gives up after the limit with `settled: false` (fake frames that keep
  changing, injected sleep).
- Rust: parsing and descriptions.
- A throwaway end-to-end run in Settings (tap a row, see the new screen;
  toggle a switch, see the value change), then the user's manual pass.

## Docs

- `docs/devices.md`: actions return what changed.
- Tick "Settle-and-diff" in `docs/plans/2026-11-04-device-panel-design.md`.
