# Linux desktop client

## Goal

Use Alas from a Linux desktop: pair with a host (local `alas-host` on the
same machine, or a Mac or Linux host over LAN or tailnet), list projects and
worktrees, run agent sessions, review changes, and open consoles.

## Starting point

The client already exists in a first form. `Alas/Resources/RemoteWeb` is a
web client of about 9k lines of plain JavaScript, with no build step:

- `alas-host` serves it (`RemoteWebAssets`, `RemoteHTTPResponder`), and the
  Linux tarball ships it beside the binary (`scripts/package-alas-host-linux.sh`).
- It already pairs, keeps several hosts (`hub-registry.js`), lists sessions,
  streams transcripts with markdown and visual and chart fences, creates
  worktrees, and shows changes, diffs and files.
- It is a PWA (`manifest.webmanifest`, `sw.js`), so Chromium can already
  install it as a windowed app with a launcher icon.

So the transport, pairing and origin questions are settled: the browser
handshake ships today. The work is turning a phone-shaped web client into a
desktop one, not writing a new client.

## Gaps

1. **Desktop layout.** The UI is built for a phone: a bottom tab bar and one
   view at a time. A desktop needs a sidebar (projects, worktrees, sessions)
   beside the transcript, with changes and files in a side panel. This is a
   wide-viewport layout over the same views, not a second app; the phone
   layout stays.
2. **Consoles.** The web client has none. The iOS app runs them over the
   peer console protocol (`PeerConsoleProtocol.swift`,
   `Mobile/Sources/Terminal`). The web side needs xterm.js speaking the same
   frames. The host serves consoles to browsers only once its owner allows
   it for that device (`alas-host browsers terminals`, or the toggle on the
   device in the Mac's Remote settings): the web client renders host-supplied
   content in the page that holds its socket.
3. **Diffs.** `changes-view.js` builds its own rows. A diff library
   (`@pierre/diffs`, from diffs.com) would give split view, syntax
   highlighting and word-level changes.
4. **Packaging.** See below.

## Packaging

In order, stopping where it is good enough:

1. **Browser tab or installed PWA.** Costs nothing. On Linux with a local
   `alas-host`, `http://localhost:<port>` is same-origin and loopback.
2. **Electron shell.** Only once something needs it: a tray icon, native
   notifications while the window is closed, a global shortcut, or starting
   and supervising a local `alas-host`. The window loads the host's URL, so
   it stays same-origin and needs no origin policy changes. It would also
   cover Windows, against remote hosts only, since `alas-host` does not run
   there.

## Decisions to make

- **Build step.** The client vendors minified libraries (`marked`, `purify`,
  xterm.js) and has no build step of its own. `@pierre/diffs` is ESM and pulls
  in Shiki, so `scripts/remote-web-bundle` bundles it with esbuild into
  `RemoteWeb/diffs`: a module the Changes view imports on first use, plus
  grammar and theme chunks loaded on demand. The output is committed, so the
  app, the Linux tarball and `alas-host` need no Node; CI rebuilds it and
  fails if it differs. The bundle keeps about 35 grammars and Pierre's themes;
  other languages show as plain text.
- **Wire drift.** The JavaScript client decodes the same messages as
  `AlasRemoteKit`. As it takes on more surface, shared JSON wire fixtures
  decoded by both the Swift and the JavaScript tests would catch drift.

## Order

1. Desktop layout behind a width breakpoint.
2. Consoles with xterm.js.
3. Bundler, then `@pierre/diffs` in the Changes view.
4. Electron shell, if the PWA falls short.

## Non-goals

- Mac app parity: editor, LSP, file tree editing, plugins, VMs, computer use,
  devices.
- A GTK client.
