# Design captures

Repeatable screenshots of Alas Dev's sidebar and agent transcript, for judging
the design. They contain demo data only, so they are safe to send to outside
model providers. No model is called: the agent is a script.

```bash
scripts/design/make-demo-profile.sh /tmp/alas-design-demo
scripts/design/capture.sh /tmp/alas-design-demo <out-dir> dark
scripts/design/capture.sh /tmp/alas-design-demo <out-dir> light
```

Each capture writes `window.png`, `sidebar.png`, `transcript.png` and `right-pane.png`. It uses
this checkout's Debug build; set `ALAS_DEV_APP` to use another. Set
`ALAS_CAPTURE_DENSITY=compact` to capture Compact. Set `ALAS_CAPTURE_RIGHT_TAB` to `files`,
`agent`, `run` or `schedules` to open the right pane on that tab.
Set `ALAS_CAPTURE_DIALOG` to `new-project`, `new-worktree`, `repo-selector`,
`review-target`, `run-script`, `agent-launcher` or `file-search` to capture with
that dialog open. Set `ALAS_CAPTURE_SETTINGS` to comma-separated Settings sections
(`general,appearance,agents`) to also write `settings-<section>.png`. Set `ALAS_CAPTURE_CLI` to an `alas`
CLI command (`open {wt}/src/billing/Invoice.swift`, `review`) to run it in the
selected worktree first; `{wt}` is that worktree's path.
Set `ALAS_CAPTURE_CENTER` to `gg-inbox` or `gg-landing` to open that gg tab (the inbox of
the demo project, or a landing in progress for its `invoice-export` stack).

Set `ALAS_CAPTURE_CENTER` to `peer-session`, `peer-permission`, `peer-diff`, `peer-file` or
`peer-console` (or `ALAS_CAPTURE_DIALOG=peer-new-session`) to capture the native views of a
paired Mac. The Debug build installs two scripted peers in-process (`DesignCaptureDemoPeer`):
no network, pairing or keychain. Their sidebar section is collapsed by default.

Set `ALAS_CAPTURE_CENTER` to `attention-inbox` or `attention-rollup` to open the Attention
inbox popover over demo rows (`DesignCaptureAttention`): action-required, informational,
last-known, acknowledged and historical items across three projects and a remote host, plus
a peer session and a cleanup reminder. The rows replace the real store's aggregation only
in this Debug build. `attention-rollup` also runs the roll-up, with scripted groups instead
of a model. The popover is composited onto `window.png` like the editor popups.

## How it works

- `make-demo-profile.sh` builds `fixture/` (the invented `lantern` repo with 14
  linked worktrees) once, and rewrites `seed/` (the app-support template) every
  time.
- `capture.sh` copies the seed to `<profile>/support`, sets the theme, launches
  Alas Dev on it, and stops everything it started. Starting from the seed each
  time matters: a run persists the replayed transcript, and the next replay
  would duplicate it.
- The seed selects a worktree with a restored chat tab and a session row with a
  remote session id. Mounting the tab calls `session/load`, and
  `fake-acp-agent.py` replays the transcript and asks for a permission.

To change what the transcript shows, edit `fake-acp-agent.py`.

## Scripted gg

`fake-gg.py` stands in for git-gud, so the gg screens have demo data. The profile
installs it as `<profile>/bin/gg` and sets `$SHELL` to `<profile>/bin/shell` for the
launch: Alas reads its PATH from `$SHELL`, and that wrapper gives it a PATH with the
fake first, so the user's own gg is never found. It answers `--version`, the
`--help` capability probes, `ls --json` (the stack of the current branch, or the
directory of all stacks), `ls --all --json`, `ls --remote --json` and `inbox`
(`--jsonl` and `--json`). Anything else exits 1 with a message and changes nothing.
The demo repo carries a gg config (`.git/gg/config.json`, branch username `nacho`),
which turns the gg screens on. Edit the stacks at the top of `fake-gg.py`.

The gg-landing capture seeds `GGLandingStore` with the events `gg land --jsonl`
would emit; no land runs. The stack drawer in the Changes tab reads "Unavailable":
the stacks' commits are not in the demo repo, and adding them would change every
other capture.

## Routes tried

**Capture.** `screencapture -x -o -l<window id>` works from the shell at native
resolution, with no prompt once the host has the Screen Recording grant, and
needs no focus. It also works while the window sits on a hidden AeroSpace
workspace. `computer_screenshot` also exists, but it caps at 1280px, shows an
approval card and can't be scripted.

**Navigation.** `alas wt switch <branch>` works. It needs `ALAS_SOCKET_PATH`
pointing at `/tmp/alas-<uid>-<hash>/hooks/pid-<pid>` and a working directory
inside the fixture repo. Agent input to Alas builds is refused, so nothing here
clicks or types.

**Populating the transcript.**

| Route | Result |
|---|---|
| `agents.worktreeAutoLaunch` | No: it only applies when a worktree is created, not when one is opened. |
| `alas session new` from a shell | Not run. The command router requires a live originating ACP session, which a shell can't provide. |
| Seeded tab and session row, replay on `session/load` | Works, and is what the scripts use. |

## Keeping captures the same

- **Window size is not pinned under AeroSpace.** AeroSpace tiles a new window on
  the focused workspace, so its size follows what is there (1648x1063pt on an
  accordion workspace, 849pt wide on a split one). `capture.sh` moves the window
  to a hidden `design-capture` workspace as soon as AeroSpace knows it, so it
  doesn't stay on the user's workspace, but it keeps the size it was tiled to.
  AeroSpace can't resize there: `fullscreen` and `layout floating` have no effect
  on a hidden workspace, and `resize` refuses floating windows. A window under
  1200pt wide fails the capture. Launch arguments set a 1440x900pt opening frame, which holds only
  until AeroSpace tiles the window.
- **AeroSpace failures.** If AeroSpace is down or never lists the window, the
  capture warns and leaves the window where it opened, on the user's screen. The
  size check still protects comparisons.
- **Rounds must use the baseline's size.** Each capture writes its size in points
  to `window-size.txt`, and the baseline keeps its own. Set
  `ALAS_CAPTURE_EXPECT_SIZE` to that value, such as `1648x1063`. With another
  size the capture exits 1 and writes no PNGs; focus a workspace with the same
  layout and run it again.
- **Opaque material.** The seed sets `sidebarMaterial` to `none`, so the sidebar
  and right pane paint the theme's `bg-0` and don't depend on what's behind the
  window. Captures therefore do not show vibrancy, so don't judge it from them.
- **Sidebar diffs.** A row shows its diff only after the worktree has been
  opened, so `capture.sh` visits every worktree with `alas wt switch` and returns
  to the selected one.
- **Readiness.** It waits for the agent's done marker, then for two captures a
  second apart to match. The comparison tolerates small changes because the
  "awaiting approval" dot keeps pulsing.
- **MCP chip.** `exposeAlasMCP` is off, so the toolbar has no MCP chip. The
  scripted agent never connects to the built-in server, and after a delay the
  chip would change to a warning.
- **Times.** Commits have a fixed date, so rows read "9 mo ago" and will drift
  with the calendar. Compare a baseline with a capture from around the same time.

Between matching runs, the only pixels that differ are in the pulsing dot. The
exception is a hover highlight: the window briefly opens on screen, and a row
under the pointer at that moment can stay highlighted. The script can't detect
this, so check the sidebar, and rerun any capture that shows a hover highlight.

## Good to know

- Chat agents run under a broker that outlives the app. `capture.sh` stops the
  brokers and agents of its own profile, matched by path, and never touches any
  other Alas instance. An app that ignores SIGTERM for 10 seconds gets SIGKILL,
  sent to that pid only.
- An isolated profile keeps preferences in its own
  `io.nlopez.alas.profile.alas-<uid>-<hash>` domain, which stays in
  `~/Library/Preferences` after a run.
- The main window's saved frame is not isolated. macOS stores it as
  `NSWindow Frame main` in the `io.nlopez.alas.dev` domain every Alas Dev build
  shares. `capture.sh` snapshots that one key and restores it on exit, including
  after a failure or a signal, and deletes it if it was absent.
