# Remote Device Hub: unattended Android access

Status: proposed for review, 2026-11-19.

## Outcome

Leave the physical K14 connected to the home Mac. From another house, open it in Alas on a paired Mac or the native iPhone app, watch an agent using it, take over to tap, swipe, or type, then hand it back. The owner sets up access at home once. Attaching, taking control, and reconnecting must not require someone at the host.

The first delivery covers already-connected physical Android devices. The K14 is the acceptance device, not a model-specific code path. iOS simulators and worktree VMs are part of the overall goal; their capture and input work gets its own scope. Physical iOS devices, audio, clipboard sync, app installs from the viewer, remote boot, and browser viewers are outside this design.

## Setup and discovery

- The home Mac runs Alas with Remote Access, Tailscale Serve over HTTPS, and Tailscale only enabled. The host is logged in and awake, and the Android device is powered, connected over USB, and authorized in ADB. Agent device tools remain a separate host setting; turn them on before starting the agent session on the home Mac.
- On the home Mac, explicitly grant a paired native Mac or iPhone access to the selected device. Grants default to off and distinguish viewing from control. Save them against the host's device identity and the pairing record, not a display name, worktree, or network address. A new pairing gets no grant. Remember approved grants across host relaunches so recovery does not require someone at home.
- On the viewing Mac, show a Devices tab for the owning peer. On iPhone, offer Devices from the paired host, without requiring an active session. Simulators and Android devices belong to the host; the worktree that last used a device is not an access rule. List only devices granted to that client, and show a granted device as unavailable when it disconnects.
- A host that does not support remote devices does not show the entry. A phone paired only with a different Mac cannot reach the K14 through session federation. Use a direct pairing with the Mac that owns the USB connection.
- Show who is driving on the host and in both clients. The owner can reclaim control, remove a grant, or stop sharing the device. Removing view access or revoking a pairing closes its video and input; removing only control leaves video running. Stopping sharing clears the device's grants and closes its remote attachments without stopping local use.

## Video and connection lifetime

Use the existing authenticated remote connection for discovery, attach and detach, status, and control. Keep H.264 off that connection. The same remote listener serves a separate binary WebSocket behind Tailscale Serve, so video does not queue ahead of agent messages or permission prompts. This adds a route to the existing server, not a public listener or a general port forward.

Only full-scope native pairings with a device grant can attach. The host issues an expiring, single-use media ticket tied to the authorized control connection, pairing, and device attachment. The client opens the media socket on the same verified HTTPS origin with no redirect or downgrade to a plaintext LAN address. The host serves the route only in Tailscale-only mode with Serve active and its listener bound to loopback; it does not trust client-supplied forwarding headers for that decision. Recheck the grant when redeeming a ticket. Closing the parent connection, disabling remote access, or revoking access invalidates outstanding tickets and closes the media socket. Do not log tickets, keys, typed text, or pixels.

Reuse `AndroidStreamClient`'s single scrcpy session per device. Forward the compressed video before the local decoder, with codec configuration, presentation timestamps, keyframe flags, and a format generation that changes on capture restart or rotation. A remote attachment can keep the stream alive without opening or focusing a host tab. Remote teardown releases only its own subscription; existing local screens and agent use keep working.

Each viewer gets bounded buffering. Start at codec configuration plus a decodable keyframe sequence; never treat an arbitrary dependent frame as a restart point. A slow viewer skips to the next decodable sequence without blocking capture or the other viewer. Bound stale-frame age as well as bytes. If it cannot recover, show the interruption and reattach. Reconnects and format changes discard stale frames; the view-only connection can resume automatically, but control does not. The iPhone detaches in the background and can reopen the stream when it returns to the foreground.

The host uses one encoding profile per active device, not an encoder per viewer. The loopback probe measured 7.3 Mbps during fast scrolling at 720 × 1600. Use a capped bitrate for the shared stream and check legibility, latency, and bitrate on the K14 over an off-LAN link. Do not claim the loopback results as network performance.

## Taking control

An attachment starts in view mode. **Take over** requests one exclusive, host-owned input lease for the device. A view-only grant cannot acquire it. A second remote viewer stays view-only while the lease is held; the local owner can always reclaim it. Remote input is enabled only after the host grants the lease. The phone uses touch gestures and its keyboard; the Mac uses pointer, wheel, and keyboard. Keep Android Back, Home, Recents, and Power available without exposing the ADB socket or arbitrary commands.

Use the existing Android input paths and `DeviceAgentControl` arbitration. The host stops or drains in-flight agent input before granting the remote driver, blocks local device input while the remote driver holds the lease, and holds new agent input using the existing timeout behavior. Viewing never delays an agent. **Hand back** releases the manual lease and lets waiting or subsequent agent calls proceed; it does not restart an agent session or retry a tool call that already timed out.

Each input names its attachment, lease generation, and the displayed format generation. The host verifies ownership and grant, maps normalized coordinates against the matching device geometry, and rejects stale input after rotation or reconnect. Touch/key start and end events stay ordered; high-frequency move events may be coalesced. On lease loss, invalidate the generation, discard queued events, and cancel active touches or release held buttons and keys before allowing another driver. If the Android transport is gone, discard the old input state and do not replay it on the replacement session.

Hand back, host reclaim, grant removal, sleep/background on the client, lost media, or lost control connection releases control. The host expires the lease on a silent connection loss even if the socket has not closed. The UI clears its control indication immediately when it knows the connection is unusable and never queues input for later delivery. This coordinates input sent through Alas; it does not lock out a person touching the physical phone or another local ADB client.

## Unattended failure cases

- A reachable host can report that Android is missing, unauthorized, or no longer streaming. A client that cannot reach the host reports it as unreachable; it cannot tell from that alone whether the Mac is asleep, shut down, or offline.
- Waking the Android screen and using its normal lock screen may work through the input path. Test those on the K14. Do not bypass Android security, store an unlock credential, or promise recovery after USB authorization is revoked, the phone is unplugged, or the host is asleep. Document what requires physical access, including what happens after a K14 reboot.
- A network interruption leaves the agent on the home Mac and removes the peer's control lease. If the device is still available, the viewer can reconnect and request a new lease. No remote input is buffered across the interruption.

## Acceptance

Cover the host contract with focused tests for grant isolation and revocation, ticket reuse and expiry, lease ownership and hand-back ordering, stale input rejection, and bounded video recovery across codec changes. Do not add tests that pin SwiftUI composition.

On the physical K14 and the device-owning Mac, set up remote access once. Use a second Mac and the physical iPhone through the tailnet, with at least the iPhone off the home LAN. Without touching the host or K14 during the remote steps:

1. Open a home-Mac agent session remotely. Have it open a benign screen on the K14 and verify the live view follows it on both clients.
2. Take over from the iPhone. Verify taps, swipe, text, and a hardware button against what the K14 actually does. The Mac remains view-only and the agent cannot inject input while the iPhone drives. Hand back and verify the agent's next input succeeds. Repeat takeover from the Mac.
3. Rotate the K14, background and foreground the iPhone, and interrupt and restore the viewer's network during a gesture. Verify that playback resumes, stale events do not arrive, and neither viewer silently regains control. Confirm that disconnecting one viewer leaves the other unaffected.
4. Revoke access at the host while a client is attached, then reconnect. Confirm that no video or input survives and the revoked client cannot reattach. Check that unplugging the phone produces an unavailable state, not a frozen frame that still looks live.
5. Measure first frame, control-to-visible-response latency, rotation and reconnect recovery, and bandwidth under scrolling. Keep a session active during a slow-viewer test and confirm its updates and permission actions still work. Check the K14 with the screen off, at its normal lock screen, and after a reboot; record which cases need someone at home.

## Extending to other Devices sources

Keep the pairing, grant, media attachment, viewer, and driver lease contracts independent of scrcpy. The Android implementation is the first source; add another source when its capture and input are proven. The iOS simulator can encode its existing IOSurface frames with VideoToolbox and send input through `AlasSimService`. macOS and Linux VMs need separate capture verification with the VM tab closed and input through the VM's driver gate. The existing guest screenshot commands are per-window snapshots, not a substitute for the console stream. Neither follow-on changes the K14 acceptance test.
