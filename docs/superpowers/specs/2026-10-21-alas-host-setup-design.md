# `alas-host` setup and configuration from the command line

## Why

`alas-host` (the headless host, `docs/headless-host.md`) can only be configured
by hand-writing `app.json`, and a Mac that runs only the host has no way to add
a project at all: the host's socket accepts `addProject`, but no shipped client
sends it. A smoke test of v0.21.10 on 2026-10-21 got a phone-style client
driving a Claude session only after writing that socket request by hand.

The host is meant to be a *narrower* Alas than the app: an always-on agent
server, reached from phones and browsers. Most of the app's ~130 settings are
window and editor settings that mean nothing there. A few change what agents do
while nobody watches, and those must be settable from a terminal, typically
over SSH on first setup.

## Goals

1. **`alas-host setup`:** a full-screen terminal UI (arrow keys, Enter, Esc)
   that walks through the settings below. It opens on the current values, so
   rerunning it is how settings get changed later. Runs fine over SSH.
2. **`alas-host config get|set <setting> [<value>]`:** the same settings, one
   at a time, for quick edits and scripts. `config list` (or `get` with no
   argument) prints them all with their values.
3. **`alas-host project add <path> [--name <name>]`, `project remove <id|path>`,
   `project list`:** manage the profile's projects without the app.
4. **`alas-host restart`:** restarts the host so new settings apply.
5. **The host honors every setting it lets you set.** Today several behavior
   settings are read only by the app (`AppState`) and passed into the core;
   the host ignores them. Each setting below must take effect on the host.
   Exposing the Alas MCP server to agents is left out on purpose: the host has
   no Alas MCP (in the app it runs through the Rust `alas` CLI and a
   per-session socket into the app, neither of which the host-only install
   has). Building one is a separate project.
6. **LAN reachability:** the host can listen on the local network, not just on
   loopback.

## The settings (the narrow set)

| Section | Setting | Notes |
|---|---|---|
| Reachability | mode: off / loopback / Tailscale / LAN (in that order) | host-only, see below |
| | port | host-only; default 8765 |
| | display name | `remote.displayName` (shared with the app) |
| Agents | which agents are enabled | built-ins (`agents.builtinState`), plus registry installs already in `app.json` |
| Projects | add / remove | see Goal 3; removal in setup asks for confirmation and is refused while the project has a running or starting session or run |
| Unattended behavior | auto-run by default | `harness.acpAutoRunByDefault` |
| | auto-resume after a usage limit | `harness.acpAutoResumeAfterUsageLimit` |
| | continue interrupted sessions | `harness.acpContinueInterruptedSessions` |
| Worktree defaults | root path, base branch | `worktrees.rootPath`, `.baseBranch`; no branch template, since the host never applies one (host requests carry the final branch name) |
| Pairing | show a pairing code at the end of setup | a QR in the terminal if cheap; the code alone is enough |

Everything else stays app-only for now: themes, fonts, panes, the editor and
language servers, plugins, local-model features, summaries, suggestions,
dictation, terminal appearance.

### Reachability modes

Reachability is the host's own setting, in a host-only part of `app.json` that
the app never reads, so changing it on a host never turns the app's Remote off
or on. The same profile can run the app at some times and the host at others
(`--wait-for-lock`). When the host-only setting is absent, the host derives it
from the shared keys as it does today (`remote.enabled`, `remote.port`,
`remote.tailscaleServe`), so existing hosts keep working unchanged.

- **off:** no Remote.
- **loopback:** serves on 127.0.0.1 only; reach it through an SSH tunnel.
  This is today's behavior, and stays the default for a host.
- **LAN:** listens on every interface. Apple's TN3179 lists *listening for and
  accepting incoming TCP connections* as not requiring local network access, so
  a command-line tool or launchd agent can serve the LAN without the Local
  Network permission. The existing protections still apply (pairing tokens,
  allowed hosts and origins). Traffic is plain HTTP, as with the app's Remote.
- **Tailscale:** loopback plus `tailscale serve`, as the host does today when
  `remote.tailscaleServe` is set.

Not in scope: Bonjour discovery (`remote.discoverable`). Advertising needs the
Local Network permission, which a launchd agent is not exempt from and often
cannot prompt for. Phones connect by address or pairing code.

The app's own rule (all interfaces unless Tailscale serve *and* Tailscale-only)
must not be copied into the host as-is: an existing headless host would start
listening on the LAN after an upgrade without anyone choosing it. LAN is an
explicit opt-in.

## Restart behavior

The host reads `app.json` once at start. After `setup` saves changes, or after
`config set`, the user chooses: **restart now** or **later**. Restarting ends
running agent sessions and runs, as a normal stop does; the prompt says so.
`alas-host restart` does it later. When the host runs as the launchd agent
(`install-agent`), restart goes through launchd. When it runs in a terminal,
`restart` cannot restart it and says to stop and start it.

`config set` prints that a restart is needed and does not restart by itself
(scripts may set several values). It could take `--restart`.

## Anti-goals

- Copying the app's Settings: no setting appears here unless the host honors
  it.
- A setting the UI lets you change that silently does nothing on the host.
- Exposing a host on the LAN without an explicit choice.
- A new third-party dependency for the terminal UI. Raw terminal mode and ANSI
  escapes in Swift are enough for menus, toggles and text fields.

## Constraints

- Lives in the `alas-host` executable target and `Packages/AlasCore`; no
  SwiftUI/AppKit (`AGENTS.md`). The host-only install ships only this binary,
  so the Rust `alas` CLI is not available there and is not the place for it.
- `app.json` is shared with the app (same data directory). Writes must keep
  every key the narrow set does not touch, and the app's lenient decoding must
  still read the file. The app and host never hold the data directory at the
  same time (the existing lock).
- Projects are added and removed through the running host when one is running
  (its socket), and directly in the profile's files when none is; either way
  the result is the same state the app would produce. The socket protocol
  needs a `removeProject` request.
- When the app, or an unidentified process, holds the data directory, `setup`, `config set` and the
  project commands refuse and say so: the app keeps its settings in memory
  and would overwrite the change. Read-only commands (`config get`,
  `project list`) still work.
- Profiles: everything honors `ALAS_APP_SUPPORT_DIR`, as the host does.
- Tests follow `AGENTS.md`'s testing policy: pin the decision logic (setting
  parsing and validation, reachability mode mapping, `app.json` merge), not
  the terminal drawing.

## Decided by the user

- Narrow scope, not parity with the app.
- A full-screen setup UI that can be rerun, plus `config set` for quick
  changes.
- Restarting to apply is fine; the user chooses now or later, and there is an
  `alas-host restart`.
- LAN reachability is wanted.
- Exposing the Alas MCP server is out of scope; the host has none to expose.
- The host's reachability is its own setting, not the app's shared Remote
  keys; absent, it falls back to what those keys say today.

## My calls (the builder may revisit)

- The terminal UI is hand-written Swift inside `alas-host`, not a library.
- Setting names in `config` are the `app.json` key paths
  (`harness.acpAutoRunByDefault`), and the host-only settings' own key paths,
  so the docs and the file agree.
- With the app holding the data directory, write commands refuse rather than
  route through the app's socket.
- Agent credentials (Claude, Codex logins, `gh auth`) stay with each tool's own
  CLI; setup only checks that an enabled agent's adapter is on the PATH and
  says so.

## Left to the builder

- The exact `app.json` representation of the host-only reachability setting.
- How the host applies the four unattended-behavior settings (whatever the
  app does in `AppState`, moved or mirrored into the host's environment).
- Screen layout, key bindings, and text-field editing details.
- Whether `setup` offers `install-agent` at the end.
