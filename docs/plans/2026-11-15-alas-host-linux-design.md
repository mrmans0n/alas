# alas-host on Linux

## Goal

Run `alas-host` on a Linux server and use it from the Mac exactly like a
headless macOS host: pair, open projects and worktrees, run chat agents,
open consoles, run scripts and schedules, shepherd PRs.

Later, the same host should be the base for a thin Linux client UI. This
plan does not build that client, but every phase keeps it possible: the
wire types live in `AlasRemoteKit`, so that module must build on Linux too
(it already builds for iOS, which is the same discipline).

## Non-goals

- Mac-only features on a Linux host: VMs, computer use, simulator/device
  control, dictation, Apple on-device models (local titles fall back to the
  agent or a plain heuristic), JavaScriptCore plugins, macOS notifications.
  The host reports each as unavailable through its capabilities; the Mac
  already hides what a host doesn't offer.
- Bonjour discovery from a Linux host. Pairing uses an address (LAN or
  tailnet), which the Mac already supports. Avahi can come later.
- A Linux Alas app. That is the future thin client.

## What is macOS-only today

`alas-host` depends on the whole `AlasCore` umbrella: ~1,000 files,
~255k lines. No file has a `#if os(...)` or `canImport` guard yet.

| Area | Where | Linux answer |
|---|---|---|
| `CryptoKit` (58 files) | identity keys, pairing, hashing | `swift-crypto` (`Crypto`), API-compatible; `#if canImport(CryptoKit)` shim in one place |
| `os` / `OSLog` `Logger` (~60 files) | everywhere | a tiny `Logger` shim in `AlasFoundation` writing to stderr (journald picks it up) |
| `Darwin` (45 files) | syscalls, `stat`, signals, sockets | `Glibc`/`Musl` via one `#if` import shim; fix the handful of Darwin-only calls |
| `Network` (8 files) | `RemoteServer`, `RemoteConnection`, port forwarding, Bonjour | The server already speaks HTTP/WebSocket by hand over plain TCP (`HTTPRequestParser`, `WebSocketFrame`). Put a small socket seam under it: `NWListener` on macOS, POSIX sockets + a dispatch read source on Linux. Bonjour and peer browsing compile out. |
| `CoreServices` FSEvents (2 watchers, 35 uses) | `WorktreeWatcher`, `ProjectGitWatcher` | An `inotify` implementation behind the same watcher seam |
| `DispatchSource.makeFileSystemObjectSource` | `alas-host/main.swift` (binary-replaced watch) | inotify, or drop on Linux (self-update is replaced, see below) |
| `Security` Keychain | `RemoteSecretStore` | Already falls back to owner-only files; use the file store directly on Linux |
| `SystemConfiguration`, `IOKit` | `RemoteNetwork`, `RemoteKeepAwakeController` | Interface listing via `getifaddrs`; keep-awake is a no-op |
| `notify`, `UserNotifications` | change notifier, attention | compile out; attention still flows to the Mac over the wire |
| `JavaScriptCore`, `FoundationModels`, `Speech`/`AVFoundation`/`CoreAudio`, `CoreGraphics`, `ImageIO`, `Compression`, `CommonCrypto` | plugins, local text, dictation, computer use, VMs, images | compile out with their features (non-goals) |
| `launchd` agent | `HostLaunchAgent`, `install-agent` | a systemd **user** unit (`~/.config/systemd/user/alas-host.service`, `loginctl enable-linger`) |
| Self-update | `HostSelfUpdate` downloads the macOS build | download the Linux tarball for the host's arch |
| Foundation gaps | `Process`, `URLSession` (FoundationNetworking), `NSRegularExpression`, run loops | fix as the compiler finds them |

Things that already work on Linux and need no redesign: git (shells out),
SSH (system `ssh`), zmx (the terminal multiplexer already ships a Linux
build for SSH projects), ACP agents (Node adapters over stdio), SQLite.

## How the code gets split

Rule: no `#if os(Linux)` sprinkled through feature code. Two mechanisms only:

1. **Seams** for things the host needs on both platforms (sockets, file
   watching, logging, crypto, secrets, process/syscall helpers). One
   protocol or shim, two implementations, chosen in one place.
2. **Compiling out** whole Mac-only features. Each one moves behind a
   single `#if canImport(<framework>)` at its boundary (or into its own
   target with a `.when(platforms: [.macOS])` dependency where the
   feature is already a clean folder: `ComputerUse`, `VM`, `Devices`,
   `Dictation`, `LocalText`, `Plugins`). Callers see an "unavailable"
   capability instead of the type.

The Mac app must build and behave exactly as before after every phase.

## Phases

Each phase is one or a few PRs, each green on macOS CI, and each adds the
modules it finished to a Linux CI lane, so progress can't regress.

1. **Linux CI lane + bottom modules.** A GitHub Actions job running
   `swift build` in the official Swift 6 Linux image, initially for
   `AlasRemoteKit` and `AlasFoundation` only. Add the crypto, logger and
   libc shims. Exit: both modules build on Linux. (`AlasRemoteKit` building
   here is what the future Linux client needs.)
2. **`AlasModel`, `AlasPlatform`, `AlasFeatures`, `AlasIntegrations`,
   `AlasCode`.** File-watch seam with inotify; secrets to files; compile out
   computer use, VMs, devices, local text, image decoding. Exit: these
   build on Linux; their existing tests that don't touch Mac-only features
   run there.
3. **`AlasACP`, `AlasSessions`, `AlasAgentKit`, `AlasAgents`.** Compile out
   plugins, dictation, notify, Apple-model titles. Exit: builds; ACP
   session tests run on Linux.
4. **`AlasHostCore` + `alas-host`.** Socket seam under `RemoteServer` and
   port forwarding; Bonjour out; network listing via `getifaddrs`;
   keep-awake no-op; capabilities report what's missing. Exit: the
   end-to-end host tests in `AlasCoreTests` pass on Linux.
5. **Packaging and service.** Release artifacts for `x86_64` and `aarch64`
   (static Linux SDK if every dependency links statically, else glibc
   tarballs), systemd user unit via `alas-host install-agent`, Linux
   self-update, zmx Linux binary bundled. Docs: install and pair from the Mac.
6. **Smoke test** on a real Linux box from the Mac: pair, open a project,
   chat agent, console, run script, schedule, PR shepherd.

Phases 1–3 are mostly mechanical. Phase 4 is the one with real design
work (the socket seam) and gets its own short design note before coding.

## Risks

- **Foundation differences** show up only at compile or run time on
  Linux. The CI lane from phase 1 is the guard; tests on Linux in phases
  2–4 catch runtime differences (e.g. `Process` termination, file
  attributes).
- **Static linking.** The static Linux SDK needs every C dependency
  (sqlite3, tree-sitter) to link statically. If that fails, ship glibc
  builds for a stated minimum distro instead.
- **CI cost.** One extra Linux job; it builds only AlasCore, no Xcode, no
  Ghostty.

## Calls I made (change any of them)

- Hand-written POSIX socket seam rather than adding SwiftNIO: the server
  already parses HTTP and WebSocket itself; it only needs a byte pipe.
- `swift-crypto` as the one new dependency (it is Apple's, and the only
  sane CryptoKit equivalent).
- No Bonjour on Linux; pair by address.
- systemd user unit, not a system service, matching the per-user launchd
  agent.
