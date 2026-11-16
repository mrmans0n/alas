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
ships it. The two casks link the same command, so install one or the other.
Outside Homebrew, the binary is inside the app at
`Alas.app/Contents/Resources/alas-host/alas-host`.

For unattended setup, use [Set up from another Mac](#set-up-from-another-mac).
After Homebrew installs a standalone host, Alas verifies the host, CLI and zmx
signatures against its release publisher before clearing that release directory's
download-confirmation quarantine. Homebrew still verifies the release's SHA256.
This changes neither system-wide Gatekeeper settings nor the `alas` app cask's
quarantine policy.

### On a Linux server

Each release attaches `alas-host-<version>-linux-x86_64.tar.gz` and
`-linux-aarch64.tar.gz`. They run on Ubuntu 22.04, Debian 12 and anything
with that glibc or newer, and need libcurl, SQLite and zlib from the system
(`apt install libcurl4 libsqlite3-0 zlib1g` on Debian and Ubuntu), plus git
and whatever your agents need (Node for the ACP adapters):

```bash
curl -fsSL https://github.com/mrmans0n/alas/releases/latest/download/install-alas-host.sh | sh
```

It unpacks the latest release into `~/.local/opt/alas-host`, links
`alas-host` into `~/.local/bin`, starts it as a systemd user service and
enables lingering so it keeps serving while you are logged out. Rerun it to
upgrade. `ALAS_HOST_VERSION=<version>` installs a given release and
`ALAS_HOST_TARBALL=<path>` a tarball you already have.

To install by hand instead:

```bash
mkdir -p ~/.local/opt/alas-host
curl -fsSL https://github.com/mrmans0n/alas/releases/download/v<version>/alas-host-<version>-linux-$(uname -m).tar.gz \
  | tar -xz -C ~/.local/opt/alas-host
ln -s ~/.local/opt/alas-host/alas-host/alas-host ~/.local/bin/alas-host
alas-host install-agent   # a systemd user service
loginctl enable-linger "$USER"   # keep it serving while you are logged out
```

Its data directory is `~/.local/share/Alas`. Pair it from the Mac by address
(the server's LAN or tailnet name; `alas-host pair` prints a link): Linux hosts
are not advertised over Bonjour. A host installed this way updates itself from
the latest release when a paired Mac asks it to. On Linux it has no VMs,
computer use, simulators, dictation, plugins or Apple's on-device model; agents,
consoles, run scripts, schedules, reviews and shepherds work as on a Mac.

### Set up from another Mac

Alas can do all of the above, plus [Configure](#configure),
[Start at login](#start-at-login) and [Pair a Mac](#pair-a-mac), over SSH. In
Settings › Remote › Peers, choose **Set up a host over SSH** and enter an SSH
destination such as `me@mini.local`. Alas connects in batch mode, so key login
must work without a password: if it can't connect, run `ssh <destination>` once
in Terminal to trust the host key.

Alas uses the host inside an installed `Alas.app` as is, updates an installed
`alas-host` cask, or installs that cask when the host Mac has Homebrew, without
running Homebrew's automatic cleanup. Otherwise, or when that install fails, it
copies its own host files into `~/.alas/host` when both Macs share an
architecture. You then pick the reachability, the agents to
enable and the projects to add. Alas installs the adapter of each enabled Claude,
Codex or Pi whose CLI is on the host Mac using that Mac's `npm`, starts the host
at login, pairs with it, and lists anything `alas-host setup --check` warns about,
along with any adapter it couldn't install. The host Mac needs
a user logged in, since launchd runs the host in that user's session.

A peer set up this way shows **Update host**, which reinstalls and restarts the
host (ending its running sessions), and **Host log**, which shows the end of its
log.

Any paired host that runs from the `alas-host` or `alas` cask as its launch
agent also shows **Update host** while it is online, set up over SSH or not.
The host finishes `brew upgrade --cask` before stopping, so replacing its
executable cannot interrupt installation. Standalone `alas-host` installs and
updates over SSH or a peer verify and authorize the release as above. On macOS, an
independent launchd helper waits for the old host to exit and explicitly starts
the service, even if launchd missed Homebrew replacing its executable symlink.
Linux's systemd service restarts it instead. Updating ends running agent sessions.

When an update disconnects a peer, the Mac waits up to 90 seconds for that
same peer's host channel to reconnect and finish subscribing. A disconnect
alone is not success; a timeout reports recovery guidance. An already-current
host keeps serving without restarting.

These host-side safeguards take effect once the updated host is installed.
An older host still runs its old updater for that first upgrade. Use the updated
Mac app's SSH setup flow to bootstrap an affected host. Its installed CLI must
be able to start for the SSH probe; an existing macOS security prompt blocking
that CLI must be resolved on the host first.

A peer's status names the host's release and says when it is older than the
Mac's Alas. Such a host also shows in the Inbox under **Host updates**, with
**Update** and **Dismiss**; a dismissed host comes back once it runs another
version.

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
`alas-host setup --check` prints those warnings, one per line, without a terminal.

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

When a Claude, Codex or Pi session on the host is missing its adapter, a paired
Mac shows **Install** next to the error. The host installs the adapter with its
`npm` and connects the session again; hosts older than this show only the error.

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
alas-host peers list                  # id, name, serverId, agent access, this host's access there
alas-host peers agents <id|name|serverId> off|ask|auto
alas-host peers remove <id|name|serverId>
alas-host peers add <pairing-link>    # let this host's agents delegate to that Mac
```

`peers remove` revokes the peer and disconnects it. Like the other commands,
these go through the running host when one serves the profile. `peers add`
works only through a running host, because it needs the host's Remote server.

`peers agents` sets whether agents on that Mac may start sessions on this host
(see [Delegating to another machine](agent-delegation.md#delegating-to-another-machine)).
It is `off` by default and after any new pairing, except the `peers add` case in
[Delegate from the host to a Mac](#delegate-from-the-host-to-a-mac). `ask` lets their sessions run
with permission requests waiting for a person; `auto` also lets a session
auto-run, if the agent that started it was auto-running. Turning it off stops new
sessions and prompts; work already running finishes and reports back.

### Delegate from the host to a Mac

A Mac that paired with the host with no link back keeps its own link to the
host open, and the host's agents can delegate to it over that link while it is
up. To allow it, set *Let agents on this Mac use this machine* on the host's
row in that Mac's Settings > Remote > Peers. A host that paired with another
host through `peers add` allows it with `alas-host peers agents <host> ask` or
`auto`. Both sides need this version, and a Mac whose pairing predates it,
which proved no key to the host, must pair again. The host's agents see the Mac in `agent_list` while its link is up; the
Mac can't be reached while it sleeps or is off the network, and children there
wait until it is back.

If the host should reach the Mac on its own, for example while the Mac's link
is down, pair the two ways instead. Choose **Pair a device** in
the Mac's Remote settings, copy the pairing link, then run
`alas-host peers add <pairing-link>` on the host. Unlike the pairing above, this
is two-way: the host redeems the link, then the Mac pairs back to the host, so
that Mac also gets a link to the host.

- The host and the Mac must be able to reach each other. Tailscale is the
  recommended route. The host needs an address other than loopback, so set
  `host.reachability` to `tailscale` or `lan`. A host that only listens on
  loopback refuses the add and says so.
- macOS may silently deny a launch agent's connections to LAN addresses, so a
  host running through `install-agent` may not reach a Mac over the LAN. This is
  untested. If the add can't reach the Mac, use Tailscale.
- The Mac must allow it: on the host's row in Settings > Remote > Peers, set
  *Let agents on this Mac use this machine*.
- The Mac needs a current Alas. The host asks it for a token that only lets the
  host delegate, and refuses a Mac that can't grant one, saying to update Alas
  there. That token can't read or drive the Mac's sessions, open terminals or
  change worktrees, so an agent on the host that reads the host's token file
  gets no more than delegation. `peers list` shows it as
  `this host there: delegation only`. The Mac's link back to the host is a full
  one, since you use it from the Mac.

When Remote serves, the host keeps a link open to each peer it holds a token for.
That includes tokens written by an app sharing the profile, not only those from
`peers add`. Agents on the host see those peers in `agent_list`, and each peer
still refuses them until it allows it.

If the Mac had paired with the host and had no link back, its `peers agents`
value stays as it was: access to the host is a separate decision. Running
`peers add` again for a Mac that already has a link back is an ordinary re-pair,
and that Mac's access starts at `off`, on its older tokens too. A token from a
pairing made before delegation-only tokens stays valid on the Mac after a
re-pair. To drop it, forget the host on the Mac first, then run `peers add`.

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
`vm_*`, `device_*`, `worktree_switch` and `workspace_*`. Calling one anyway, or its CLI command,
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
profile fires on the host, and a script run gets a run console. A terminal
agent gets a console too, named after the agent, which a paired Mac can open
from the worktree's terminals. The host types the schedule's prompt there once
it sees the agent running, as the app does, and leaves it unsent when the
schedule asks for review. A chat agent's schedule that leaves its prompt for
review fails each time with the reason; it runs only in the app. On an SSH
project the host starts chat agents, and makes a schedule's new worktree, on
the project's machine as the app does; a script or a terminal agent there
fails with the reason, because the host has no terminal on that machine. Its
chat sessions share the profile's server id with the app, which the host
assigns at start when the profile has none. Shepherd records of
SSH-project worktrees are left untouched for the app. Shepherd and schedule
settings are read when the host starts: run `alas-host restart` after changing
them. Their alerts go to paired Macs, which show them as banners.

A paired Mac's session toolbar shows a host session's shepherd pill. Its menu
offers **Ship with agent** when the session shepherds nothing, and `/ship` in
the composer does the same. As in the app, the host shepherds the branch's open
pull request with the session; without one, it sends the session the app's
Ship prompt, so the agent opens the pull request or ships the gg stack and the
host shepherds it. It also offers **Resume** for a shepherd that needs
attention and **Stop shepherding**.

When no session shepherds a worktree's open pull request, the review drawer
in the Mac's Changes tab offers **Shepherd with…**, listing the worktree's
sessions the host drives. Picking one runs that session's Ship on the host,
which binds the pull request to it. Starting a new session for it stays in
the app.

While a session shepherds the pull request, the drawer shows its phase and
the **Auto-fix** and **Auto-merge** switches, which the host applies to that
shepherd, with **Resume**, **Stop shepherding** and **Move to…**, which hands
the pull request to another of the worktree's sessions. This needs a host
that serves `host.shepherds.toggles.v1`; an older one leaves the drawer to
the session's toolbar pill.

Whether a project's worktrees are gg stacks follows the host's settings, not
the Mac's: the master switch, the project's mode, and gg on the host's `PATH`
when it starts. A paired Mac sets the project's mode from the project's
context menu in the sidebar, under **Stacked Diffs Mode**: Off, Auto (when the
repository has `.git/gg/config.json`) or On.

A host worktree whose branch is a gg stack by the host's settings shows the
stack in the Mac's Changes tab instead of the pull request drawer: its entries
with their pull requests, CI and approvals, read again when you refresh. When
gg is missing on the host, or has no branch username, the drawer says so.
Its **Sync** pushes the stack and opens or updates its pull requests, and
**Rebase** moves it onto its base when it is behind. An operation paused on
conflicts offers **Continue** and **Abort** once they are resolved in the
changes list. An entry whose pull request, and every one below it, is
approved and green offers **Land**, which merges them from the bottom of the
stack after you confirm. **Reorder…** opens the same sheet as on the Mac;
merged entries stay where they are. Every action is checked again on the host
when its turn comes, and refused if the stack changed since the Mac read it.

## Start at login

```bash
alas-host install-agent
```

installs a launchd agent (a systemd user service on Linux) that starts the host
at login, waiting while the app has the profile open, and restarts it if it
stops. Its output goes to
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

- **SSH-project scripts and terminal agents.** Their schedules run only in the app.
