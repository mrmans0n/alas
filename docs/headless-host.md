# Headless host (`alas-host`)

`alas-host` runs Alas without its window: it serves a profile's projects,
worktrees, agent sessions and run scripts to clients on its local socket, and,
when Remote is on, to paired phones and browsers. Use it on a Mac that should
keep agents available while nobody is at it, such as an always-on Mac mini.

It uses the same data directory as the app, so the projects, sessions and
settings you set up in the app are the ones it serves. The app and the host
never run on the same data directory at once: whichever starts second refuses,
naming the process that holds it.

## Install

With the app, `alas-host` is already on your `PATH`:

```bash
brew install --cask mrmans0n/tap/alas
```

Without the app, on a Mac that only runs the host:

```bash
brew install --cask mrmans0n/tap/alas-host
```

The `alas-host` cask is published with each release from the first one that
ships it. The two casks link the same command, so install one or the other. Outside
Homebrew, the binary is inside the app at
`Alas.app/Contents/Resources/alas-host/alas-host`.

## Run

```bash
alas-host
```

It prints the path of its socket and serves until you stop it with Ctrl-C or
`SIGTERM`, which ends agent sessions and runs before it exits.

The data directory is `~/Library/Application Support/Alas`, or the one
`ALAS_APP_SUPPORT_DIR` names for an isolated profile. If the app has that
directory open, `alas-host` exits and says which process holds it;
`alas-host --wait-for-lock` waits for it to close instead.

## Configure

```bash
alas-host setup
```

walks through reachability, agents, behavior, worktrees, projects and pairing in
a full-screen terminal UI that opens on the current values. Rerun it to change
them later. It warns about an enabled agent whose adapter it cannot find.

To script it, or change one thing:

```bash
alas-host config list
alas-host config get host.reachability
alas-host config set host.reachability tailscale --restart
alas-host project list
alas-host project add ~/code/my-repo --name "My repo"
alas-host project remove ~/code/my-repo
alas-host restart
```

The settings are `host.reachability`, `host.port`, `remote.displayName`,
`agents.<id>.enabled` (one per built-in or installed agent),
`harness.acpAutoRunByDefault`, `harness.acpAutoResumeAfterUsageLimit`,
`harness.acpContinueInterruptedSessions`, `worktrees.rootPath` and
`worktrees.baseBranch`. Booleans take `true`/`false`, `on`/`off` or `yes`/`no`.
They are stored in the profile's `app.json`; settings you never change take
their defaults.

`project remove` takes the id or path that `project list` prints. Reads work any time. Writes, including `project add` and `project remove`, are
refused while the app, or any process other than the host, holds the profile.
A change applies after a restart: `alas-host restart` restarts a host run by the
launch agent (below), and `config set --restart` does both. A host run in a
terminal must be stopped with Ctrl-C and started again.

Agents come from the same file: the built-in ones you enable under `agents`, and
agents installed from the ACP registry. The host launches an adapter with its
own `PATH` plus well-known directories such as Homebrew's, so an adapter must be
on the host's `PATH` or in a location like `/opt/homebrew/bin`. The login
shell's `PATH` does not apply, notably when launchd starts the host.

## Remote

Remote is served according to `host.reachability`:

- `off`: not served.
- `loopback`: `127.0.0.1` only.
- `tailscale`: loopback, plus `tailscale serve` for the port.
- `lan`: all interfaces, so other devices on the network reach it directly.

`host.port` sets the port. Without `host.reachability`, the host follows
`remote.enabled`, `remote.tailscaleServe` and `remote.port` as before: loopback,
or Tailscale when serve is on. LAN is used only when you choose it. It serves
plain HTTP, and Bonjour discovery stays off, so clients enter the address. A
command-line program can serve the LAN without macOS's local network permission:
accepting incoming TCP connections does not need it (Apple TN3179).

The host prints its address:

```
remote http://127.0.0.1:8765
```

Other ways to reach a loopback host:

- **Tailscale.** Choose `tailscale`. When the tailnet has HTTPS enabled, the
  host runs `tailscale serve` for its port and prints the
  `https://<machine>.<tailnet>.ts.net` address to use.
- **An SSH tunnel**, from the device or a machine it can reach:
  `ssh -L 8765:127.0.0.1:8765 <host-mac>`.

The host serves the web client that ships with it, so a browser can open the
address directly.

### Pair a phone or browser

On the host Mac, while the host runs:

```bash
alas-host pair
```

It prints a pairing code, valid for two minutes, to enter in the Alas phone app
or the web client. Devices you paired with the app on this profile stay paired.

Other Macs cannot pair with a headless host or connect to it as a peer: Mac
pairing needs an approval prompt and an identity key that only the app holds.

## Start at login

```bash
alas-host install-agent
```

installs a launchd agent that starts the host at login, waiting while the app
has the profile open, and restarts it if it stops. Its output goes to
`alas-host.log` in the data directory. After an app or cask upgrade the agent
restarts on the new version; once the app or cask is uninstalled, it stops.

```bash
alas-host uninstall-agent
```

stops it and removes it. Each profile has its own agent, so run these with the
same `ALAS_APP_SUPPORT_DIR` you serve.

## What it does not do yet

- **Terminals.** Terminal tabs and peer consoles need the app; a Remote client
  can't open them on a headless host.
- **The `alas` CLI and its MCP tools.** They talk to the app, so agents
  running under a headless host can't use them to open reviews, answer review
  comments or start delegated sessions, and Remote clients can't reach those
  either.
- **Linux.** The host is macOS only.
