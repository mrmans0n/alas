# Peer hover card and local peer icon override

## Why

The spaces pager shows each paired Mac as a 22 pt glyph with a presence dot
and a waiting count; hovering only gives a `.help` tooltip ("name · state").
The user wants to see what a Mac is doing and how it is connected without
switching to its page. Separately, a peer's icon is whatever that Mac
advertises, so there is no way to make two Macs look different on this one.

## Goals

- Hovering a peer in the pager shows a card with the Mac's state, its
  sessions and its connection, as in the approved mockup (states A, B, C).
- The user can pick a local icon for any paired Mac that wins over the one it
  advertises, and reset back to it.

## Non-goals

- Clicking inside the card. It is read-only (approach A); acting stays on the
  pager item (click opens the page) and its context menu (Edit…).
- macOS version: nothing sends it today; adding it needs protocol changes.
  Revisit only if missed.

## Approaches (card)

- **A. Read-only card on the existing click-through presenter (chosen).**
  Reuses `AgentBadgePopoverPresenter`, the 350 ms open delay and the
  close-on-any-click behaviour, so focus never moves and it behaves like
  every other hover card.
- B. Interactive card that stays open while the pointer is over it and
  accepts clicks. Rejected: a hover bridge plus focus handling, and the only
  hover card in Alas that behaves differently.

## Card content

Width 280, same chrome as `AgentBadgePopover` (header, chip, middle, hairline,
footer).

- **Header:** `PeerIconTile`, name, and a mono subtitle: `alas-host <version>`
  when the peer reports a host version, otherwise its last address.
- **Chip:** presence dot + state label; when online, the connection kind
  derived from the last address: `*.ts.net` or `100.64.0.0/10` → "Tailscale",
  `.local` or a private IPv4/IPv6 → "LAN", otherwise the host name; then the
  latest round trip ("23 ms"). The peer link sends a WebSocket ping every
  10 s while online and times its pong. Not #2744's `ping` message: that one
  exists because browsers cannot send control pings, and older hosts ignore
  it, while every host answers control pings.
- **Online (A/B):** four counts (waiting, working, terminals, worktrees), then
  up to three rows: "Waiting on you" when any wait, else "Working". Row =
  status dot, session title, branch.
- **Not online (C):** a plain sentence per state (offline, revoked, identity
  mismatch, unverified, incompatible) and no session data.
- **Footer:** Access (agent access / token scope), Identity (verified or
  not), Update available when `HostUpdateReminder` has one for it, Last here
  (`PairedMacEntry.lastSeenAt`) when not online, Paired date. Last line:
  `⌥⌘N switch` and "Right-click to edit".
- The `.help` tooltip on the pager item goes away (the card replaces it).

## Icon override

- `RemotePeer` gains `iconOverride: PeerIcon?`, persisted with the record and
  never touched by `adoptHelloIdentity`. `displayIcon` is
  `iconOverride ?? icon`.
- Everything that shows a peer icon reads `displayIcon`, including the
  `RemoteHelloPeer` list this Mac's server sends, so the pager, sidebar,
  inbox, card, and phones or browsers viewing through this Mac all agree.
- The paired-Mac sheet's 40 pt header tile becomes a `PeerIconPicker`, with a
  "Use <name>'s own" item that clears the override.

## Left to the builder

- Where the card model is assembled (a plain struct built from
  `NativePeerGroup` + `PairedMacEntry`/`RemotePeer`), so its wording and the
  connection-kind derivation can be unit tested without views.
- Tests: connection-kind derivation and the override surviving a hello. No
  view tests.
