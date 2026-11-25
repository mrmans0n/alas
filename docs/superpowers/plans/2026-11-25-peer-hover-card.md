# Peer hover card and local icon override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only hover card for paired Macs in the spaces pager, and a local icon override per paired Mac.

**Architecture:** The override is a field on `RemotePeer` (AlasHostCore) read through `displayIcon`, which also feeds `helloPeers`, so every surface follows. The card is a plain model built in the app from `NativePeerGroup` + `RemotePeer` + devices, drawn in the existing click-through hover panel (`AgentBadgePopoverPresenter`) after the modifier is made generic.

**Tech Stack:** Swift 5.9, SwiftUI/AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-25-peer-hover-card-design.md`

## Global Constraints

- AlasCore must not import SwiftUI/AppKit; `AlasRemoteKit` stays Foundation-only.
- Strings in English; card width 280, same chrome as `AgentBadgePopover`.
- Card is read-only: no clickable content, closes on any click/key/scroll.
- No view tests. Tests only for connection-kind derivation and override decoding.

## Review Focus

- A record written by an older build (no `iconOverride` key) still decodes — pinned in Task 1.
- An override id this build doesn't know must not drop the peer store — pinned in Task 1.
- IPv6 private (`fd..`, `fe80::`) and bracketed origins (`ws://[fd00::1]:7420`) read as LAN — pinned in Task 2.
- Offline peers show no session rows even if stale sessions exist (`NativePeerGroup` already clears them when not online).
- Pager hover must not open the card while the context menu is open (presenter closes on right-click).

---

### Task 1: Local icon override in core

**Files:**
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Pairing/RemotePeer.swift`
- Modify: `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/RemotePeerManager.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/PeerIconTests.swift`

**Interfaces:**
- Produces: `RemotePeer.iconOverride: PeerIcon?`, `RemotePeer.displayIcon: PeerIcon?` (`iconOverride ?? icon`), `RemotePeerManager.setIconOverride(_ icon: PeerIcon?, peerId: String)` (saves, updates durable snapshot, fires `onFederationEvent?(.availabilityChanged(serverId:))`), `helloPeers` uses `displayIcon`.

- [ ] Test `aRecordDecodesItsIconOverride(json fragment → expected)` parameterized: key absent → nil; `"macStudio"` → `.macStudio`; `"toaster"` → nil, with the rest of the record intact.
- [ ] Run `swift test --package-path Packages/AlasCore --filter PeerIconTests`, expect fail.
- [ ] Add the field (coding key `iconOverride`, `try?` decode like `icon`), `displayIcon`, setter, `helloPeers` change.
- [ ] Run tests, expect pass. Commit `feat(peers): let this Mac override a paired Mac's icon`.

### Task 2: Connection kind derivation

**Files:**
- Create: `Packages/AlasCore/Sources/AlasRemoteKit/Connection/PeerConnectionKind.swift`
- Test: `Packages/AlasCore/Tests/AlasCoreTests/PeerIconTests.swift` (peer presentation lives there)

**Interfaces:**
- Produces: `public enum PeerConnectionKind: Equatable { case tailscale, lan, host(String) }`, `static func of(origin: String?) -> PeerConnectionKind?`, `var label: String` ("Tailscale", "LAN", host).

- [ ] Parameterized test: `wss://m1max.tail1234.ts.net` → .tailscale; `ws://100.101.2.3:7420` → .tailscale; `ws://100.63.0.1:7420` → .host("100.63.0.1"); `ws://m1max.local:7420` → .lan; `ws://192.168.1.4:7420`, `ws://10.0.0.2`, `ws://172.20.1.1`, `ws://[fd00::1]:7420`, `ws://[fe80::1]:7420` → .lan; `wss://mac.example.com` → .host("mac.example.com"); nil / `""` → nil.
- [ ] Implement with `URL(string:)?.host` (strip brackets), IPv4 octet checks, IPv6 `fc/fd/fe80` prefix. Run, pass, commit `feat(peers): name how a paired Mac is reached`.

### Task 3: App reads the override; edit sheet picker

**Files:**
- Modify: `Alas/Sources/Remote/Settings/PairedMacEntry.swift` (`icon` → `peer?.displayIcon`)
- Modify: `Alas/Sources/App/AppState+PeerIcons.swift`, `Alas/Sources/Remote/AppState+HostUpdates.swift` (`peer.icon` → `peer.displayIcon`)
- Modify: `Alas/Sources/Remote/Native/PeerIconView.swift`: extract `PeerIconGrid(selection: PeerIcon, resetTitle: String?, onPick: (PeerIcon) -> Void, onReset: () -> Void)` used by `PeerIconPicker`'s popover.
- Modify: `Alas/Sources/Remote/Settings/RemoteServerPane.swift` `pairedMacSheet`: when `peer` is non-nil, the header `PeerIconTile` is a plain button opening a popover with `PeerIconGrid`, `resetTitle: "Use \(name)'s own"` shown only while an override is set; picks call `state.remotePeers.setIconOverride`.

- [ ] Build (`xcodebuild … -quiet build`), expect success. Commit `feat(peers): pick a paired Mac's icon from its sheet`.

### Task 4: Hover card

**Files:**
- Modify: `Alas/Sources/Sidebar/AgentBadgePopover.swift`: make the modifier generic (`HoverCardModifier<Card: View>`, `make: @MainActor () -> Card?`); add `func hoverCard<Card: View>(_ make: @escaping @MainActor () -> Card?) -> some View`; `agentBadgePopover` forwards.
- Create: `Alas/Sources/Sidebar/PeerHoverCard.swift`: `struct PeerHoverCardModel` (name, icon, state, subtitle, connection, counts waiting/working/terminals/worktrees, rows `[(title, branch, waiting: Bool)]` max 3, footer facts `[(label, value)]`, shortcut `Int?`) with `static func make(group:peer:lastSeenAt:hostVersion:updateVersion:agentAccess:shortcut:)`, and `struct PeerHoverCard: View`.
- Modify: `Alas/Sources/Sidebar/SpacePagerIndicator.swift`: replace `.help` on peer items with `.hoverCard { makePeerCard(peer.serverId) }`; new `let makePeerCard: @MainActor (String) -> PeerHoverCard?`.
- Modify: `Alas/Sources/Sidebar/SidebarView.swift`: pass the closure building the model from `state`.
- Run `xcodegen` (new file) and commit both.

Card rules (from the spec): subtitle = `alas-host <v>` if host version else last origin host; chip = state label + `· <connection label>` when online; online → counts + rows ("Waiting on you" if any waiting, else "Working"; status `streaming` counts as working); not online → `NativePeerState.unavailableDetail(peerName:)`; footer: Agents (Off / Ask for approval / Allow auto-run), Identity ("Verified key"/"Unverified"), Update ("<v> available") when reminded, Last here when not online, Paired date; last line `⌥⌘N switch` when N ≤ 9, "Right-click to edit".

- [ ] Build, expect success; check the card in a live run. Commit `feat(sidebar): show a hover card for paired Macs in the pager`.
