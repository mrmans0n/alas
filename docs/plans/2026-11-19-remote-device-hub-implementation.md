# Remote Device Hub implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive the physical K14 from a paired Mac or iPhone away from home, with live video and explicit takeover and hand-back to the host's agent.

**Architecture:** The home Mac owns access, capture, and input. Device messages on the existing paired connection authorize and control an attachment; a second WebSocket on the same verified HTTPS origin carries bounded, binary video. Android supplies already-encoded H.264 from its existing scrcpy session, and both native viewers use the same playback and attachment logic.

**Tech Stack:** Swift 6, Swift Testing, AlasRemoteKit, AlasHostCore, scrcpy 5.0.1, Tailscale Serve, CoreMedia, AVFoundation, SwiftUI/AppKit/UIKit.

**Spec:** [`2026-11-19-remote-device-hub-design.md`](2026-11-19-remote-device-hub-design.md), approved at `4adb4dfa9a`.

## Global constraints

- First delivery: already-connected physical Android devices. The K14 is the acceptance device, not a code path. No remote boot, audio, clipboard sync, install, browser viewer, or session federation routing. iOS simulators and worktree VMs reuse the contracts later, not speculative provider implementations now.
- The device-owning Mac must be logged in, awake, and running Alas. Tailscale only and Serve over HTTPS must both be on for remote devices. Native clients attach directly; no plaintext fallback or public listener, and no separate ADB access.
- A grant defaults to off, is scoped to a persisted pairing and host-local device, and can allow view or control. One controller at a time; viewing cannot delay the agent. Keep control down on recovery until the user explicitly retakes it.
- macOS deployment target 15.0; iOS deployment target 26.0. AlasRemoteKit stays usable from iOS without AVFoundation or UI code. AlasCore remains UI-free and its tests must run without the app build.
- Follow `AGENTS.md`: English strings, Swift Testing, regenerate and commit generated projects alongside edited `project.yml` files. Use selective commits, no attributions. Do not log tickets, video, input text, credentials, or USB serials sent to unauthorized clients.

## Review focus

1. Same model name or newly paired client: no inherited grant; disabled Secure Remote or revoked grant closes the attachment (Tasks 1–2).
2. Two concurrent ticket redemptions, old parent link, or forged proxy headers: at most one media socket, never one after invalidation (Task 2).
3. A slow viewer or a new rotation with an old dependent frame: other viewers and session traffic continue; the lagging decoder can only restart on matching config and keyframe (Tasks 3 and 5).
4. Takeover during an agent input turn; disconnect during a touch: old work cannot reach the device after another driver is active (Task 4).
5. Backgrounding or changing hosts mid-attach: a late response cannot show another device or restore control (Task 5).

---

## Task 1: Device protocol and local grants

**Files:** Add `Packages/AlasCore/Sources/AlasRemoteKit/PeerDeviceProtocol.swift` and `Packages/AlasCore/Sources/AlasHostCore/Remote/Devices/PeerDeviceGrants.swift`. Extend `Packages/AlasCore/Sources/AlasRemoteKit/Protocol/RemoteProtocol.swift`; update exhaustive consumers, including the remote gateway and web-message tests if applicable. Add `Packages/AlasCore/Tests/AlasCoreTests/PeerDeviceProtocolTests.swift` and `PeerDeviceGrantsTests.swift` in the same test directory.

**Produces:** `PeerDeviceRequest` / `PeerDeviceEvent` on `.device(...)` of both remote envelopes; `PeerDeviceCapability.v1` negotiated with `hello`; `PeerDeviceID` is an opaque UUID. `PeerDeviceGrants` maps this ID to physical Android ADB serial on the host and tracks `PairingID → view | control`. Control includes viewing. Persist through a small Application Support store beside `FileDeviceStore`; use atomic replacement and publish edits only after a successful save. Grants and pairings are separate, so an old grant never matches a new pairing ID.

- [ ] Add regressions for a wire round-trip, unknown capability compatibility, and grant isolation. For example, in the grant suite, with a temporary store:

  ```swift
  let allowed = try grants.setAccess(.control, serial: "serial-A", pairingID: "phone-A")
  let restored = try PeerDeviceGrants(file: file)
  #expect(restored.access(to: allowed, pairingID: "phone-A") == .control)
  #expect(restored.access(to: allowed, pairingID: "phone-B") == nil)
  #expect(restored.sharedIDs(for: "phone-A") == [allowed])
  #expect(restored.sharedIDs(for: "phone-B").isEmpty)
  ```

  Add a second Android with the same display name; it must still require its own grant. Test downgrading and deleting a grant after reopening the store.
- [ ] Implement wire cases for list; attach/detach; take/release/renew control; input; and state, refusal, and detach events. The attach request carries a fresh `attachmentID` and `PeerDeviceID`. The reply echoes the attachment ID and gives a ticket, not an arbitrary media URL. Input carries `attachmentID`, `leaseGeneration`, `formatGeneration`, and a typed event. Keep status values distinct for absent, Android unauthorized, Android offline, and capture interrupted. Unrecognized wire messages retain the current skip behavior.
- [ ] Run `swift test --package-path Packages/AlasCore --filter 'PeerDevice(Protocol|Grants)Tests'`; check both suites ran. Commit the wire and grant contract without advertising an unimplemented capability.

## Task 2: Authenticated attachment and binary route

**Files:** Add `Packages/AlasCore/Sources/AlasHostCore/Remote/Devices/PeerDeviceHost.swift` and `PeerDeviceTickets.swift`. Modify `Packages/AlasCore/Sources/AlasHostCore/Remote/Server/{RemoteConnection,RemoteServer}.swift`, `Remote/Gateway/{RemoteSessionGateway,RemoteSessionPresenter}.swift` in that package, and `Alas/Sources/App/AppState.swift`. Extend `AlasTests/Remote/RemoteServerIntegrationTests.swift`; add `Packages/AlasCore/Tests/AlasCoreTests/PeerDeviceTicketsTests.swift`.

**Consumes:** Task 1's request/event, device grants, and existing pairing records. **Produces:** A host-owned attachment table keyed by `(controlLinkID, attachmentID)`, binary `GET /ws/device-media`, and a `RemoteSessionPresenter.peerDeviceHost` defaulting to `nil`. The media sink exposes a tracked binary write and close, not raw socket access to the Android implementation.

- [ ] Write ticket tests with an injected monotonic clock. Assert that a second redemption of the same ticket fails, a ticket past its deadline fails, and invalidating a link makes an outstanding ticket unusable. Example with the new ticket book:

  ```swift
  let first = tickets.issue(for: attachment, now: .zero)
  #expect(tickets.redeem(first, now: .seconds(1)) == attachment)
  #expect(tickets.redeem(first, now: .seconds(1)) == nil)
  let second = tickets.issue(for: attachment, now: .zero)
  tickets.invalidate(linkID: attachment.linkID)
  #expect(tickets.redeem(second, now: .seconds(1)) == nil)
  ```

- [ ] Implement issue/redeem/revoke on the host actor. Generate a 256-bit random ticket, 15-second lifetime, at most one pending or active media connection per attachment. Redeem atomically and recheck the active parent, exact pairing and device grant, and host serving policy before accepting. Do not accept tickets in the URL; pass them as a WebSocket subprotocol token through the existing upgrade machinery. Keep `/ws` behavior for regular clients and do not construct a session gateway for the media connection. Accept only close, ping, and pong from the viewer after the media upgrade. Do not negotiate WebSocket compression for H.264. Close makes outstanding tracked writes irrelevant and removes the attachment.
- [ ] Wire its availability to actual loopback binding, Remote Access enabled, Tailscale only, and the Serve process serving the current port. Reevaluate on config, Serve, and port changes. Do not derive security from `Host`, `Origin`, or proxy headers; continue applying the server's existing connection and origin checks. Only `.alasInstance` and `.phone` of `.full` scope receive a device link. Inject the same presenter seam as consoles; no capability or route for headless hosts or unready app hosts. Stop/rebind/Forget closes attachments and invalidates tickets. Keep connection IDs separate from pairing IDs so an old teardown cannot close a replacement link.
- [ ] Extend `RemoteServerIntegrationTests` using the existing loopback fixture: valid ticket delivers a binary frame from a test source; a second upgrade is refused; a revoked device link closes its media socket; a disabled policy denies a request even with a forged `X-Forwarded-Proto: https`; existing `/ws` messages still arrive as JSON. Inject the server eligibility state in the fixture, not in product defaults. Run the focused ticket suite and `xcodebuild` for `AlasTests/RemoteServerIntegrationTests`. Commit working transport with the production device capability still off pending the Android source and grants UI.

## Task 3: One Android capture, independently bounded viewers

**Files:** Extend `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/Scrcpy.swift` and `Packages/AlasCore/Tests/AlasCoreTests/ScrcpyTests.swift`. Add `Packages/AlasCore/Sources/AlasRemoteKit/PeerDeviceVideo.swift`, `Packages/AlasCore/Sources/AlasHostCore/Remote/Devices/PeerDeviceVideoFanout.swift` and `Packages/AlasCore/Tests/AlasCoreTests/PeerDeviceVideoTests.swift`. Modify `Alas/Sources/Devices/Android/{AndroidStreamClient,AndroidScreenSession}.swift`. Add `Alas/Sources/Devices/Android/AndroidPeerDeviceSource.swift`.

**Consumes:** Task 2's tracked media sink. **Produces:** `PeerDeviceVideoPacket` with format, config, and frame variants; a physical-device source able to subscribe without any open local tab. Local decoded observers and remote encoded observers keep separate tokens on the same session.

- [ ] Extend the chunk-boundary parser test to assert the exact microsecond PTS and keyframe flag after an interleaved session/format header. Add a generation test with two tracked sinks; keep one write pending while the fast sink drains. Feed encoder config, key, delta, rotate, then new config and key. Assert the fast sink received both generations in order and that the slow sink, when allowed to resume, receives generation two's config and key before any delta. Exercise age and byte limits by advancing the fake clock and feeding oversized data, not by sleeping.
- [ ] Preserve PTS from the low 61 bits of scrcpy's media header. Fan config and compressed frames out immediately before decoding. Decode only while local frames are needed; if a local observer joins an already-running source, wait for current config and a keyframe. Start with `video_bit_rate=4000000` and `video_codec_options=i-frame-interval:int=1` for one shared encoding profile. Verify the actual keyframe cadence and bitrate on the K14; Android encoders can ignore options. No restart or secondary encoder on remote join. Keep final teardown tied to the last local, agent, or remote token.
- [ ] Use a versioned fixed-size binary header with explicit kind, generation, and payload length, plus dimensions or PTS/key flag as appropriate. Refuse truncated packets, invalid lengths and unknown kinds before allocating decoder buffers. Keep at most one tracked write in flight per viewer; cap pending data at 512 KiB and 500 ms in the queue. Keep a separately bounded, contiguous GOP for late joins: config plus keyframe and all dependent frames through the current image, or nothing. An idle screen can reuse that GOP even when its source PTS is old; a partially cached GOP must wait for a new keyframe. Drop backlog on overflow or format change; restart only with matching config and a keyframe. Test a late join to an idle screen after advancing the clock. If no usable keyframe or write progress for five seconds while recovery is pending, close only that media connection. An idle stream not waiting for recovery remains live. Restart capture only when the physical stream itself failed.
- [ ] Run `swift test --package-path Packages/AlasCore --filter 'ScrcpyTests|PeerDeviceVideoTests'`, then the app build. Verify the K14 using the local Devices tab and a temporary in-process encoded observer: dimensions, rotation, attach without restarting local playback, and last-subscriber teardown. Remove the ephemeral observer. Commit capture and delivery.

## Task 4: Host input ownership and sharing controls

**Files:** Extend Task 2's `PeerDeviceHost.swift` and Task 3's `AndroidPeerDeviceSource.swift`. Modify `Alas/Sources/Devices/{DeviceAgentControl,DeviceScreenView}.swift`, `Alas/Sources/Devices/Android/{AndroidDeviceStage,AndroidActions,AndroidStreamClient,AndroidScreenSession}.swift`, and `Alas/Sources/Remote/Settings/RemoteServerPane.swift`. Wire `Alas/Sources/App/AppState.swift` and a new `Alas/Sources/App/AppState+PeerDevices.swift`. Extend `AlasTests/DeviceAgentControlTests.swift` and add `AlasTests/PeerDeviceHostTests.swift`.

**Consumes:** Task 1 grants, Task 2 links, Task 3 format generation and stream lifetime. **Produces:** One host-serialized owner per device and one host settings section to grant view/control, revoke, stop sharing, and reclaim local input.

- [ ] Write a `DeviceAgentControlTests` regression holding an input turn with a continuation. Request takeover; assert no remote input reaches the fake backend while the earlier agent turn is held. Release the turn, await the lease, and confirm the next agent turn stays held until hand-back. In the host suite drive a remote pointer down, lose the media connection, and verify the backend receives pointer cancellation before any newly admitted input. Verify old lease and format generations are refused with no device event, including when the same peer obtains a new lease.
- [ ] Reserve remote takeover on the existing main-actor device arbitration before awaiting drain, then wait for earlier input turns/gesture cancellation to finish. Block new agent input and local mutation paths, including settings and flows, while the reservation or remote lease is active. Do not make viewing or a rejected takeover change the driver. Hide control actions until capture is ready and both links are live. Check the attachment, device, grant, generation and format for every event, finite coordinates in `0...1`, and bounded text/event sizes. Reject invalid input, do not feed an arbitrary Android command. Reuse the existing scrcpy paths for Back/Home/Recents/Power and key/pointer input. Use the existing Android text path for typing, with no client clipboard synchronization. Verify the actual scrcpy cancel/release path, including key modifiers and first input after rotation.
- [ ] Renew the control lease from the active viewer every two seconds; expire after six without a renewal. On loss, invalidate generation and drop queued input first; cancel the pointer and release recorded keys through the current Android transport before reopening input. If that transport is gone, discard its input state. Revocation, downgrade, hand-back, media close, control link close and reclaim call the same release path. Store no leases on disk. Publish the named driver and observe grant changes without restarting remote sessions. Extend `Packages/AlasCore/Sources/AlasFeatures/Devices/Android/AndroidDevice.swift` and its existing parser suite to preserve the `usb:` field from `adb devices -l`. Grant and attach only physical USB Android devices; do not substitute `!isEmulator` for a USB check. Keep granted but unavailable devices listed without enabling attach.
- [ ] Add grant editing to host Remote settings with eligible pairings and physical devices, plus driver/reclaim in the local Android stage. Stop sharing clears that device's grants and tears down remote attachments without stopping local clients. Exercise this on the K14 and run `xcodebuild` for `AlasTests/DeviceAgentControlTests`, `AlasTests/PeerDeviceHostTests`, and `AlasTests/RemoteServerIntegrationTests`. Commit the host-side behavior.

## Task 5: Shared native attachment and playback, then paired Mac UI

**Files:** Add `Alas/Sources/Remote/Native/{PeerDeviceSession,PeerDevicePlayback,NativePeerDevicesView}.swift`; put platform-specific shells in separate files if needed so the two shared files can also compile in iOS. Modify `Packages/AlasCore/Sources/AlasRemoteKit/Connection/RemotePeerConnection.swift`, `Packages/AlasCore/Sources/AlasHostCore/Remote/Peer/RemotePeerManager.swift`, `Alas/Sources/App/AppState+PeerConsoles.swift` only if needed to reuse connection lifecycle wiring, and `Alas/Sources/Right/{RightPaneState,NativePeerRightPaneView}.swift`. Add `AlasTests/PeerDeviceSessionTests.swift`.

**Consumes:** Tasks 1–4. **Produces:** `PeerDeviceSession` with an injected typed control sender and verified-origin provider, plus shared media playback. No AVFoundation in AlasRemoteKit. The Mac right-pane Devices tab is capability-gated and keyed by owning peer, not by selected session.

- [ ] Test using a controlled media opener: select device A, close/reselect B before A's reply, deliver A's reply and media data late, and assert they cannot render or acquire control. Deliver a new format's delta before config/key and assert it never reaches playback. In a client origin test, refuse non-HTTPS and redirect attempts rather than sending a ticket to a different origin.
- [ ] Expose the actual verified control origin for the active native connection; clear it with the connection. Open only the fixed media path with `wss`, on that exact origin, with a URLSession delegate refusing redirects. A control message can carry a ticket, not a new URL. Tie every receive/reconnect task to host and attachment identity; close it when either changes. Flush old samples and disable input on format changes until a correctly sized frame is displayed; fit the frame without stretching, and map input only inside displayed pixels. Convert H.264 config to a CoreMedia format and Annex B to decoder samples, preserve PTS, and enqueue to the sample-buffer renderer without a playback-sized buffer. Bound pending samples using renderer readiness; resync by reattaching when a decoder can no longer safely catch up.
- [ ] Deliver typed device events to the Mac viewer via `RemotePeerManager`; keep selection and subscription local to the visible peer tab. Add the list, live screen, driver, Take over/Hand back, Back/Home/Recents/Power, wheel/pointer/keyboard, and connection status. Do not send moves or keys when control is absent or frame geometry is stale. Verify the real Mac surface, and run the focused app suites `AlasTests/PeerDeviceSessionTests` and `AlasTests/RemotePeerConnectionTests`. Commit the Mac viewer.

## Task 6: Native iPhone viewer

**Files:** Add `Mobile/Sources/Hosts/PeerDevicesView.swift`. Modify `Mobile/Sources/Hosts/{PeersView,HostHub}.swift`, `Mobile/project.yml`, and `Mobile/AlasMobile.xcodeproj/project.pbxproj`. Include the two shared files from Task 5 in the mobile app target only. Reuse the existing background `disconnectAll()` in `Mobile/Sources/App/AlasMobileApp.swift` rather than opening a parallel host connection.

**Consumes:** Task 5 session and playback, Task 1 device protocol already decoded by `PhoneProtocol`'s generic envelopes. **Produces:** Devices from the host row without an agent session; a fullscreen native viewer with the same grants and ownership as the Mac.

- [ ] Route direct device events through a host-scoped subscription in `HostHub`; do not put them in session transcript listeners. Add the host-row entry only if the host advertises support. On entering the screen create a fresh attachment; on leaving or backgrounding detach and clear input state. In foreground, reopen view access where granted, never restore a lease. Present absent device, USB authorization, capture restart and unreachable host as different states.
- [ ] Host the same display layer in UIKit. Map finger gestures in the displayed rectangle, preserve cancellation, support local keyboard focus and text events, and give Back/Home/Recents/Power and Take over/Hand back accessible controls. Ignore any second simultaneous pointer rather than accidentally turning it into the first. Keep offline taps and keys out of any retry queue.
- [ ] Run `cd Mobile && xcodegen`, then `xcodebuild -project Mobile/AlasMobile.xcodeproj -scheme AlasMobile -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO build` from the root. Verify the iOS Simulator build against the paired host's real K14 stream. Check that an unsupported paired host exposes no Devices entry, and background a live view to check that it returns view-only. Commit `project.yml` and its generated project together, with the iPhone viewer.

## Task 7: Off-LAN acceptance on the K14 and operator docs

**Files:** Extend [`docs/devices.md`](../devices.md) with setup, access controls and recovery limits. No new manual switch to bypass peer grants or TLS for testing.

- [ ] Verify iPhone signing with the Debug development team from `Config/AlasMobile-Local.xcconfig`; build for the physical device with `xcodebuild -project Mobile/AlasMobile.xcodeproj -scheme AlasMobile -destination 'id=<physical-device-id>' -skipPackagePluginValidation build`. Install the Debug bundle alongside release. Build the host/peer Mac app with the repository's Debug build command. Provide the second Mac with the same reviewed build and pair both native clients to the owning Mac over Tailscale HTTPS. Enable Keep awake on power on the plugged-in host if the owner wants it; do not claim this prevents lid-close or explicit sleep. Test the normal network and signing setup, not a substitute public stream.
- [ ] With the physical iPhone off home Wi-Fi, start a home-Mac agent session from the phone. Watch the K14 on both viewers while the agent opens a benign app. Take over on the phone, test tap/swipe/text/hardware button, verify the Mac and agent cannot inject while it holds control, then hand back and observe the agent succeed. Repeat takeover from the paired Mac. Record capture-to-first-frame and input-to-visible-response against real actions, along with bitrate during scrolling. Keep a host session active while one media viewer is slow; verify permission actions and the other viewer remain usable.
- [ ] Rotate, background the iPhone during input, switch the client network off during a gesture, and reconnect. Verify no stuck gesture or returning lease. Reclaim locally, downgrade to view-only, revoke the grant and pairing, and verify each restriction with an active attachment and a subsequent new one. Unplug/replug USB, test the authorized screen-off and normal lock-screen paths without storing credentials, and reboot the K14 once with the owner ready to recover it. Record actual failures, especially cases requiring a person at home. Do not make a remote reboot feature part of the test.
- [ ] Document the supported setup, tested recovery cases and limitations. Run the affected AlasCore suites first and the focused app suites listed above, confirming their test counts. Report the device and network observations separately from automated results. If the physical devices or network are temporarily unavailable, report the specific missing verification and do not mark this acceptance complete.

### App test command

Run the affected selections per task, not the full app plan:

```bash
xcodebuild -project Alas.xcodeproj -scheme Alas -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation \
  -only-testing:AlasTests/RemoteServerIntegrationTests test
```

For new Swift files in an explicitly generated target, regenerate with `xcodegen` at the project root (or in `Mobile`) before testing, then include the changed `.pbxproj` in the same task commit. Use `commit.draft()` for each task's commit, selecting only that task's files.
