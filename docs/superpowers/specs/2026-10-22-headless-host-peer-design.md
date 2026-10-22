# Headless host as a Mac peer — phase 1 design

## Intent

A Mac mini runs `alas-host` (no app window) so agents stay available. Today the
Mac app on a laptop can't use it: Mac-to-Mac pairing is refused by the host.
The user wants to pair the laptop with the mini "as normal", without keeping a
visible Alas instance open on the mini, which also makes updating easy (it's a
CLI). The long-term goal is **parity with local sessions wherever possible**.

Work is split in phases:

1. **This document:** pairing plus sessions at parity.
2. Later: run scripts and worktree controls in the app's peer UI.
3. Later: terminals (peer consoles) on a headless host.

## Setting

- The laptop is on the same LAN or tailnet as the mini, with its own Remote
  turned on. That means the existing reciprocal pairing works: the mini pairs
  back to the laptop's advertised origins (confirmed with the user).
- The app and the host never share a data directory: they are different Macs.

## Goals (phase 1)

1. **Pairing.** `alas-host pair` prints a full pairing link (the same format as
   `RemotePairingLink.build`, with the host's reachable addresses) as well as
   the code. Pasting the link into the app's Add Peer completes pairing with no
   approval prompt on the mini. The mini pairs back to the laptop like an app
   does, and the peer then shows as connected and verified.
2. **Identity.** The host holds an Ed25519 identity key
   (`RemoteIdentityKeyProvider`), which it uses as the server's `signer`, the
   `/pair` reply's `identityProof`, and the `publicKey` it advertises on the
   pair-back. It's created on first run and must persist across restarts and
   upgrades.
3. **Accepting Mac peers.** `admitsPeers = true`. The host gets a
   `RemotePeerManager` with a `FilePeerStore` that stores peers in the profile,
   and `onPeerPaired` is wired as in `AppState` (`notePeerPairingArrived` plus
   the inbound pair-back). The host does **not** connect out to peers' sessions
   or federate them: it is a server for Macs, not a client.
4. **Open sessions, in place of the tab strip.** The host keeps a persisted list
   of open sessions per owner. A headless `RemoteSessionPresenter` serves it:
   - `sessionTabIndex`: position in the owner's open list, or nil.
   - `openSessionTab`: the same checks as the app's `openSessionTabNow` (the
     stored row exists and isn't archived, and the worktree exists). It then
     loads the session's manager if needed and appends the session. Already
     open counts as success.
   - `closeSessionTab`: removes the session. It stays in history. A live
     session's runner is disposed as the app does when a tab closes.
   - `sessionCreated`: appends, so a session created from the laptop
     auto-opens there.
   - `sessionRenamed`: no-op (nothing to show).
   - `sessionListChanges`: fires on every open, close or create.
   - `peerConsoleHost`: nil.
   - Opens and closes for one session run one at a time, as in the app's
     `serializedSessionTabAction`.

   The list is the host's own, separate from the app's saved tabs (user's
   decision): switching the mini between the app and the host shows different
   open sets, and that is accepted. It is shared by every client (laptop,
   phone, browser), as an app's tab strip is. It survives a host restart: on boot the host loads the
   managers for owners that have open sessions, so those sessions are listed
   again.
5. **Session list parity.** The laptop sees what it would see from a Mac running
   the app: open sessions as tabs, plus the recent unarchived sessions of each
   local worktree as history. Today only managers already loaded in the
   process are listed, so the host must make each configured local worktree's
   stored sessions listable without anyone opening them first.
6. **Agents and models.** `listAgents` lists the enabled agents, which is what
   the app serves too: for local worktrees it does not detect installation
   either (checked while planning, `AgentAvailabilityStore.state`). A model
   catalog (`ACPAgentModelCatalog`), persisted in the profile and fed by
   sessions' advertised models, gives the new-session sheet models and efforts
   once an agent has run once.
7. **Honest capabilities.** A headless host does not advertise
   `peerConsole.v1` or `peerConsoleTerminate.v1`. The capability list becomes
   per-server, not a hard-coded constant.
8. **Peer management (my call).** `alas-host peers list` prints the paired Macs
   and `alas-host peers remove <id or name>` revokes one, disconnecting it. This
   is how a lost laptop gets cut off from the mini. A laptop's own "Forget"
   keeps revoking on the host as it does today.
9. **Docs.** Update `docs/headless-host.md`:
   - Remove "Other Macs cannot pair".
   - Document pairing a Mac with the link.
   - Note that the laptop must have Remote on and be reachable from the host.

## Non-goals (phase 1)

- Terminals and peer consoles (phase 3).
- Run-script and worktree-delete controls in the app's peer UI (phase 2).
- Nearby (Bonjour) discovery and approval-prompt pairing. The host has no UI,
  and Bonjour needs a local-network grant that launchd agents can't get.
- The host consuming other peers' sessions, or federation.
- Remote/SSH-project sessions on a headless host. These are still refused, as
  today.
- Live run output.

## Anti-goals

- **No change the laptop app needs.** An already-released app should pair with
  the new host and open its sessions. App-side changes are allowed only where
  a released app can't work at all, and must be called out.
- **No weakening of pairing security.** No unverified peer may carry sessions.
  Pairing codes are minted only by the local user (`.localUser` on the socket),
  as today.
- **No UI-coupled code in the core package.** The presenter, identity and peer
  manager wiring live in `AlasHostCore` or `alas-host`.

## Constraints

- `AGENTS.md`:
  - The core package must not import UI frameworks.
  - `swift test --package-path Packages/AlasCore` must keep passing.
  - Follow the testing policy: few, sharp tests.
- Key storage: `RemoteSecretStores.makeDefault()` (Keychain, with a fallback to
  owner-only files) is acceptable. Whatever it picks must be stable across
  restarts of an ad-hoc-signed binary, so a Keychain write that later becomes
  unreadable is not acceptable.
- Identity key (my call): the host never deletes a key copy it didn't write.
  It reads the profile's existing key (from the Keychain or the file) and,
  when it has to persist one, writes the owner-only file. This way an app and
  a host taking turns on one profile keep the same key.
- A profile can hold both an app-era key (from when the app ran on that
  profile) and peers paired by the app. If the host can read them, it reuses
  them, so a Mac paired with the app on the mini earlier keeps working.

## Left to the builder

- Where the open-session list file lives in the profile, and its format.
- How worktree session rows become listable at boot: eager manager creation, or
  reading stored rows without a manager.
- Exact `alas-host pair` output layout.
- Test selection, per the testing policy. Suggested pins:
  - presenter open, close and create ordering;
  - the open list survives a restart;
  - a pairing round trip between a host and a `RemotePeerManager` in-process;
  - a headless hello omits the console capabilities.
