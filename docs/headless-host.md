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
agents installed from the ACP registry. The host reads the `PATH` of your shell
when it starts (as an interactive login shell, so setup in `.zshrc` counts), and
launches adapters with it ahead of its own plus well-known directories such as
Homebrew's, so adapters installed through nvm, fnm, asdf or mise work, launchd
agent included.

To install agents from the [ACP registry](https://agentclientprotocol.com) on a
Mac without the app:

```bash
alas-host registry search goose       # id, name, version, and whether it is built in or installed
alas-host registry install goose      # then agents.goose.enabled turns it on or off
alas-host registry uninstall goose
```

Agents that ship with Alas, such as Claude, Codex or Gemini, are built in and
not installed from the registry; their `agents.<id>.enabled` turns them on or
off. Agents install into the profile's data directory. Like `config set`, these
refuse while the app has the profile open, and a running host uses the change
once restarted.

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

The host prints its addresses: loopback and, when it listens beyond loopback,
the addresses a pairing link offers, one per line:

```
remote http://127.0.0.1:8765
remote http://192.168.1.20:8765
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

It prints the code on the first line of stdout and a pairing link on the
second. The code is valid for two minutes (stderr says until when); enter it in
the Alas phone app or the web client. Devices you paired with the app on this
profile stay paired. When every address the host serves is loopback, stderr
also notes that only this Mac or a tunnel reaches it.

### Pair a Mac

A Mac running the app pairs with the host as a peer and sees its projects and
sessions. On the host Mac, run `alas-host pair`. On the other Mac, paste the
link into Settings > Remote > Peers > Add peer.

That Mac's Remote must be on. A Mac on this version pairs with the host over
the LAN or tailnet with no connection back to it. An older app version still
needs the host to reach it, for example over Tailscale, because the host pairs
back to it.

```bash
alas-host peers list                  # id, name, serverId
alas-host peers remove <id|name|serverId>
```

`peers remove` revokes the peer and disconnects it. Like the other commands,
both go through the running host when one serves the profile.

Sessions opened from a Mac stay open for every client (laptop, phone, browser)
and survive a host restart. The host keeps that list itself, separate from the
app's tabs.

## Terminals

A Mac's peer view offers "New Terminal" on the host's worktrees. It opens a
login shell in the worktree, with the same PATH the host gives agents. Shells
run in zmx, so they survive host restarts. The app on the same profile doesn't
list or kill them, and they reappear in the peer view once the host is back.
Worktrees of SSH projects are refused.

zmx ships in the cask's zip beside the host. Otherwise the host uses the one in
`/Applications/Alas.app`; with neither, stderr says so and Macs offer no
terminals here. Set `ALAS_ZMX_BINARY` to use another zmx; a path that isn't an
executable turns terminals off.

The launch agent can't show privacy prompts, so a shell in a protected folder
(Desktop, Documents, Downloads, iCloud Drive, removable volumes) may fail to
read it without asking. Keep worktrees outside those folders, or grant
alas-host Full Disk Access in System Settings › Privacy & Security.

## The alas CLI and MCP tools

Agents the host starts get the built-in `alas` MCP server and the `alas` CLI
on their PATH, as in the app, so they can list and create worktrees, open and
answer reviews of local changes, a branch or a pull request, start and drive delegated
sessions, create pull requests and send notifications. The settings toggle
that exposes the tools in the app turns them off here too.

Pull requests are created and watched on the host: fix prompts, auto-merge and
archive after merge follow the project's shepherd rules. This needs `gh` (or
`glab` for GitLab) installed and signed in for the host's user; `alas-host
setup` reports when it isn't.

Tools that need a screen are hidden: `open`, `preview_*`, `computer_*`,
`worktree_switch` and `workspace_*`. Calling one anyway, or its CLI command,
fails with "Not available on a headless host."

When an agent opens a review or replies to a review comment, each paired Mac
shows a notification banner.

The CLI ships in the cask's zip at `alas-cli/alas`, and the host installs it
into the data directory's `bin/` at start. Otherwise the host uses the one in
`/Applications/Alas.app`; with neither, stderr says so and agents get no
`alas` tools. Set `ALAS_CLI_BINARY` to use another CLI; a path that isn't an
executable turns the tools off.

`notify` shows no banner on the host. An agent's notice goes to the paired
Macs connected to it, which show it as their own notification, and with
`--needs-input` every Remote client lists the session as waiting for input
until its next prompt. A host shell's `alas notify` comes from no session, so
it reaches nobody.

Agents reach the host through the socket in their environment. A host shell
has none, so `alas` there finds the host by scanning for its socket, which
works only on the standard profile, not on an `ALAS_APP_SUPPORT_DIR` one.

## Shepherds and schedules

The host runs PR and stack shepherds and the scheduler. A schedule saved in the
profile fires on the host, and a script run gets a run console. A schedule for
a terminal agent, for an SSH project, or one that leaves its prompt for review
fails each time with the reason; those run only in the app. Shepherd records of
SSH-project worktrees are left untouched for the app. Shepherd and schedule
settings are read when the host starts: run `alas-host restart` after changing
them. Their alerts go to paired Macs, which show them as banners.

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

Rerun `alas-host install-agent` after upgrading from a version before terminals,
so the agent runs at standard priority.

## What it does not do yet

- **Linux.** The host is macOS only.
- **Terminal-agent and SSH-project schedules.** They run only in the app.
- **Starting or stopping a shepherd from a paired Mac.**
