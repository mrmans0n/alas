# Set up a headless host over SSH — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From Settings › Remote › Peers, turn any Mac reachable over SSH into a paired `alas-host` in one flow: install or update the host, configure it, start it at login, pair, and later update it or read its log.

**Architecture:** A UI-free `HostSSHSetup` in `AlasHostCore` probes the remote with one SSH script, decides how to install (`brew` cask, existing install, or a copy of the app bundle's host files), runs the configure / install-agent / pair steps through an injected runner, and returns the pairing link. The app wraps it in a sheet and hands the link to `RemotePeerManager.addPeer(link:)`. A new `alas-host setup --check` prints the setup UI's warnings without a terminal so the sheet can show them.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing, `/usr/bin/ssh` + `/usr/bin/scp` via the existing `RemoteExec` / `SSHCommand`.

**Spec:** this document (design agreed in chat on 2026-11-02; the user approved the flow below).

## Design (agreed)

Today: ssh in, `brew install --cask mrmans0n/tap/alas-host`, `alas-host setup`, `alas-host install-agent`, `alas-host pair`, paste the link into Add peer. New: **Set up a host over SSH…** in Settings › Remote › Peers.

1. **Connect.** The user enters an SSH destination (`nacho.lopez@mini.local`). Everything runs in SSH batch mode (`RemoteExec`, `SSHCommand.scpArgv`), so a missing key or untrusted host key fails fast. On exit status 255 the sheet says: run `ssh <destination>` once in Terminal to trust the host and check key login works.
2. **Probe** (one script): `uname -s`, `uname -m`, the `brew` path, whether the `alas-host` or `alas` cask is installed, an existing host executable (`command -v alas-host`, `~/.alas/host/alas-host/alas-host`, `/Applications/Alas.app/Contents/Resources/alas-host/alas-host`), its `shasum -a 256`, and `alas-host config list` from it when one exists.
3. **Install method** (decided from the probe, in this order):
   - not macOS → unsupported ("alas-host runs on macOS only").
   - `alas-host` or `alas` cask installed → `brew upgrade --cask <that cask>` (a no-op when current), host at `$(brew --prefix)/bin/alas-host`.
   - `brew` present → `brew install --cask mrmans0n/tap/alas-host`.
   - `/Applications/Alas.app`'s host present → use it as is (the user's own app; not ours to replace).
   - remote arch == the bundle's host arch → copy: the app bundle's `alas-host/alas-host`, `RemoteWeb/`, `zmx/zmx` and `alas-cli/<arch>/alas` (the layout `HostShellLaunch.bundledBinary` looks for), tarred locally, `scp`'d, unpacked into `~/.alas/host.new`, then swapped into `~/.alas/host`. Skipped when the remote host's sha256 equals the bundle's.
   - otherwise → unsupported, naming the arch mismatch and suggesting Homebrew.
4. **Configure** (sheet, prefilled from the probe's `config list`): reachability `lan` or `tailscale` (current value when it is one of those, else `lan`), one toggle per `agents.<id>.enabled`, and remote project paths (one per line, may be empty). Applied with `alas-host config set …` per changed key and `alas-host project add <path>` per path.
5. **Start** with `alas-host install-agent` (launchd, so no Local Network trap; it boots out a running agent first, so it also restarts after an update). If it fails, the error says the host Mac needs a logged-in user session (launchctl `gui/<uid>`).
6. **Pair**: poll `alas-host pair` until it succeeds (the agent needs a moment to serve), 1 s apart, 30 s deadline; its second stdout line is the link. The app calls `addPeer(link:)` and stores the destination on the new peer.
7. **Check**: `alas-host setup --check` lines (missing adapters such as the Claude ACP adapter, gh/glab missing or signed out, no zmx / CLI) are shown on the done screen as warnings.

For a peer that has a stored SSH destination, its row offers **Update host** (re-runs probe → install → `install-agent`, after a confirmation that it restarts the host and ends its sessions) and **Host log** (`tail -n 300` of `~/Library/Application Support/Alas/alas-host.log`, shown in a monospaced sheet).

Non-goals: Linux hosts; isolated `ALAS_APP_SUPPORT_DIR` profiles on the remote (the flow targets the standard profile); password / 2FA SSH prompts (batch mode only); a host-version field in the peer protocol (sha256 comparison covers the copy path; brew owns its own versions); registry agent installs from the sheet.

## Global Constraints

- `HostSSHSetup` lives in `Packages/AlasCore` and imports no SwiftUI/AppKit; everything the app uses is `public`.
- Tests use Swift Testing, no fixed `Task.sleep`: the pair poll takes an injected `sleep` closure.
- No real SSH in tests: the runner is a closure seam; SSH is a process, so fakes are allowed by AGENTS.md.
- UI strings in English, sentence case, matching `RemoteServerPane`.
- Conventional Commits; no attribution trailers.

## Review Focus

1. A remote whose `alas-host` cask is installed but `brew` is not on the batch PATH: the probe must use the same augmented PATH as `RemoteExec` (`/opt/homebrew/bin`, `/usr/local/bin`).
2. A step failing midway (e.g. `config set` refused because the app is open on the host): setup stops there and shows that step's stderr, nothing later runs.
3. Re-running setup on an already-paired host: `addPeer` returns no error and the destination ends up on that peer (match by peer id diff, else by `serverId` of the link's host).
4. Quoting: project paths with spaces and quotes reach `project add` intact (`SSHCommand.shellQuote`).
5. `alas-host pair` stdout with only the code line (an old host): treated as failure with a message, not a crash.

---

### Task 1: `alas-host setup --check`

**Files:**
- Modify: `Packages/AlasCore/Sources/alas-host/Setup.swift`, `Packages/AlasCore/Sources/alas-host/Commands.swift` (dispatch), `Packages/AlasCore/Sources/alas-host/main.swift` (usage text)
- Modify: `docs/headless-host.md` (Configure section: one sentence)

**Interfaces:**
- Produces: `alas-host setup --check` prints one warning per line on stdout (empty output when all is well) and exits 0; needs no terminal and no lock.

- [ ] **Step 1:** Add `HostSetup.check()` that reuses `missingAdapterCommands(config)` (one line per agent: `Agent <id>: <command> not found on the host's PATH`), `codeHostSignInNotice(projects)` (its lines), and `HostShellLaunch.zmxBinary(executable:)` / `cliBinary(executable:)` being nil (`zmx not found: peers can't open terminals here`, `alas CLI not found: agents get no alas tools`). Route `["setup", "--check"]` to it.
- [ ] **Step 2:** `swift build --package-path Packages/AlasCore --product alas-host` succeeds; run it with `ALAS_APP_SUPPORT_DIR=$(mktemp -d)` and check it prints and exits 0 without a TTY (`</dev/null`).
- [ ] **Step 3:** Commit `feat(alas-host): print setup warnings with setup --check`.

No unit test: the logic it calls is already covered; this is wiring.

### Task 2: `HostSSHSetup` core

**Files:**
- Create: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/HostSSHSetup.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/HostSSHSetupTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct HostSSHProbe: Equatable, Sendable {
      public var os: String; public var arch: String
      public var brew: String?; public var cask: String?           // "alas-host" or "alas"
      public var hostPath: String?; public var hostSHA256: String?
      public var reachability: String?; public var agents: [(id: String, enabled: Bool)] // from config list
      public static func parse(_ output: String) -> HostSSHProbe
  }
  public enum HostSSHInstall: Equatable, Sendable {
      case brewUpgrade(cask: String), brewInstall, existing(path: String), copy, upToDate(path: String), unsupported(String)
      public static func decide(_ probe: HostSSHProbe, bundleArch: String, bundleSHA256: String?) -> HostSSHInstall
  }
  public struct HostSSHSetupOptions: Equatable, Sendable {
      public var reachability: String; public var agents: [String: Bool]; public var projects: [String]
  }
  public struct HostSSHSetup: Sendable {
      public struct Failure: Error, Equatable { public let step: String; public let message: String; public let connectionFailed: Bool }
      public typealias Run = @Sendable (_ command: String, _ timeout: TimeInterval) async throws -> ProcessResult
      public typealias Upload = @Sendable (_ localPath: String, _ remotePath: String) async throws -> ProcessResult
      public init(destination: String, bundleResources: URL, run: Run? = nil, upload: Upload? = nil, sleep: (@Sendable (Duration) async throws -> Void)? = nil)
      public func probe() async throws -> HostSSHProbe
      public func install(_ probe: HostSSHProbe, progress: @Sendable (String) -> Void) async throws -> String   // host executable path on the remote
      public func configure(host: String, probe: HostSSHProbe, options: HostSSHSetupOptions) async throws
      public func start(host: String) async throws            // install-agent
      public func pair(host: String) async throws -> String   // link
      public func check(host: String) async -> [String]
      public func log() async throws -> String
      public static func pairingLink(fromPairOutput: String) -> String?
  }
  ```
  Defaults: `run` → `RemoteExec.run(host: destination, cwd: nil, command:timeout:)`; `upload` → `Process.run(SSHCommand.scpExecutable, args: SSHCommand.scpArgv(...))`; `sleep` → `Task.sleep(for:)`. Bundle arch is `RemoteZmxInstaller.localArch` mapped to `uname -m` names (`aarch64` → `arm64`).

- [ ] **Step 1: Write failing tests** (`HostSSHSetupTests`):
  - `probeParsesItsScriptOutput`: a canned output with `os=Darwin`, `arch=arm64`, `brew=/opt/homebrew/bin/brew`, `cask=alas-host`, `host=…`, `sha=…`, then the `config list` lines `host.reachability = tailscale`, `agents.claude.enabled = true`, `agents.codex.enabled = false` → the matching struct.
  - `installDecision` parameterized over: Linux → unsupported; cask `alas` → `.brewUpgrade("alas")`; brew only → `.brewInstall`; `/Applications/Alas.app/...` host, no brew → `.existing`; `~/.alas/host` host with equal sha → `.upToDate`; different sha → `.copy`; no host, `x86_64` vs bundle `arm64`, no brew → unsupported mentioning Homebrew.
  - `pairingLinkIsTheSecondLine`: `"123456\nhttp://a/?code=…\n"` → link; `"123456\n"` → nil.
  - `configureQuotesProjectPathsAndSetsOnlyChangedKeys`: fake runner records commands; options change reachability and one agent and add `~/code/it's here` → exactly those `config set` calls plus one `project add` with the path shell-quoted.
  - `aFailingStepStopsWithItsStderr`: runner returns exit 1 + stderr `refused: the app has the profile open` for `config set` → throws `Failure(step: "Configure", message: <that stderr>, connectionFailed: false)`; exit 255 → `connectionFailed: true`.
  - `pairPollsUntilTheHostServes`: runner fails `pair` twice then succeeds; injected sleep records calls → link returned after 2 sleeps; always failing → throws after the 30 s deadline (count sleeps, no real time).
- [ ] **Step 2:** `swift test --package-path Packages/AlasCore --filter HostSSHSetupTests` → fails (type missing).
- [ ] **Step 3:** Implement. Probe script prints `key=value` lines then `--config--` then `config list` output. Copy: `tar -C <Resources> -czf <tmp>.tgz alas-host RemoteWeb zmx/zmx alas-cli/<cliArch>/alas` locally (`/usr/bin/tar`), upload to `.alas/host.tgz`, remote `rm -rf ~/.alas/host.new && mkdir -p ~/.alas/host.new && tar -xzf ~/.alas/host.tgz -C ~/.alas/host.new && rm -f ~/.alas/host.tgz && rm -rf ~/.alas/host && mv ~/.alas/host.new ~/.alas/host`. `install-agent` failure message appends: "The host Mac needs a user logged in (launchd runs the host in that user's session)." Log path: `"$HOME/Library/Application Support/Alas/alas-host.log"`.
- [ ] **Step 4:** Tests pass; `swiftformat --lint` clean.
- [ ] **Step 5:** Commit `feat(remote): set up a headless host over SSH in AlasCore`.

### Task 3: Remember a peer's SSH destination

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Pairing/RemotePeer.swift` (`public var sshDestination: String?`, init param defaulted nil)
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/RemotePeerManager.swift` (`public func setSSHDestination(_ destination: String?, peerId: String)`, persisting via the store)

- [ ] **Step 1:** Add the field and setter; existing peer files decode (optional). No new test: Codable optional + a setter that mirrors existing mutate-and-save paths. Run `swift test --package-path Packages/AlasCore --filter RemotePeer` to keep peer suites green.
- [ ] **Step 2:** Commit `feat(remote): remember the SSH destination of a host set up over SSH`.

### Task 4: The sheet and peer actions

**Files:**
- Create: `Alas/Sources/Remote/Settings/HostSSHSetupSheet.swift`
- Modify: `Alas/Sources/Remote/Settings/RemoteServerPane.swift` (row button "Set up a host over SSH…" under Add peer; per-peer "Update host" and "Host log" when `sshDestination` is set)
- Run `xcodegen` (new file) and commit `project.yml`-generated changes.

**Interfaces:**
- Consumes: Task 2's `HostSSHSetup`, Task 3's `setSSHDestination`, `state.remotePeers.addPeer(link:)`, `describe(_:viaLink:)` for add errors.

- [ ] **Step 1:** Sheet states: `.destination` (field + Connect) → `.options(probe, install)` (shows what will happen in one line, e.g. "Installs alas-host with Homebrew" / "Copies alas-host from this app" / "Already up to date"; reachability segmented `LAN`/`Tailscale`; agent toggles; projects multi-line field; Set up) → `.running([step lines])` → `.done(peerName, warnings)` or `.failed(Failure)` (255 hint per design §1; Back keeps entered values). Unsupported install disables Set up and shows the reason. Peer destination stored by diffing peer ids before/after `addPeer`, else the peer whose origins contain the link's first origin.
- [ ] **Step 2:** Update host: confirmation alert ("Updating restarts the host and ends its running sessions."), then probe → install → start, progress in the row's description, errors in `peerError`. Host log: sheet with a scrollable monospaced `Text` of `log()`.
- [ ] **Step 3:** `xcodegen`, then the build command from AGENTS.md (`-quiet build`) — deferred to CI per local constraints; at least `swift test --package-path Packages/AlasCore --filter HostSSHSetupTests` and `swiftformat --lint` on the touched files.
- [ ] **Step 4:** Commit `feat(remote): set up, update and read the log of a host over SSH`.
- [ ] **Step 5:** `docs/headless-host.md`: a short "Set up from another Mac" section under Install; commit `docs: describe setting up a host over SSH`.
