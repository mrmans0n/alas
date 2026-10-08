import Darwin
import Foundation
import Testing
@testable import Alas

@Suite struct PeerConsoleInputFilterTests {
    private static let esc = "\u{1B}"

    @Test(arguments: [
        "ls -la\r",
        "\(esc)[A\(esc)OB",                                   // cursor keys, normal and application mode
        "\(esc)x",                                            // Alt+x
        "\(esc)[1;5C",                                        // Ctrl+Right
        "\(esc)[3~\(esc)[15;2~",                              // Delete, Shift+F5
        "\(esc)[97;5u",                                       // kitty-protocol Ctrl+a
        "\(esc)[200~pasted\ntext\(esc)[201~",                 // bracketed paste
        "\u{03}\u{7F}\t",                                     // Ctrl-C, backspace, tab
    ])
    func userInputPassesThrough(input: String) {
        var filter = PeerConsoleInputFilter()
        #expect(filter.filter(Data(input.utf8)) == Data(input.utf8))
    }

    @Test(arguments: [
        "\(esc)[?62;22c",                                     // DA1 reply
        "\(esc)[>1;10;0c",                                    // DA2 reply
        "\(esc)[24;80R",                                      // cursor position report
        "\(esc)[0n",                                          // status report
        "\(esc)[?2004;1$y",                                   // DECRPM
        "\(esc)[?1u",                                         // kitty keyboard status
        "\(esc)]11;rgb:0000/0000/0000\u{07}",                 // OSC color reply, BEL
        "\(esc)]10;rgb:ffff/ffff/ffff\(esc)\\",               // OSC color reply, ST
        "\(esc)P1+r544e=787465726d\(esc)\\",                  // XTGETTCAP reply
        "\(esc)[I\(esc)[O",                                   // focus in/out
        "\(esc)[8;40;120t",                                   // window size report
        "\(esc)[<0;10;5M",                                    // SGR mouse the host did not ask for
        "\(esc)[M !!",                                        // legacy X10 mouse
        "\(esc)[32;10;5M",                                     // legacy rxvt/1015 mouse
    ])
    func terminalRepliesAreDropped(reply: String) {
        var filter = PeerConsoleInputFilter()
        #expect(filter.filter(Data(reply.utf8)).isEmpty)
    }

    @Test func sgrMouseReportsGoThroughOnlyWhileTheHostUsesSGR() {
        var filter = PeerConsoleInputFilter()
        let press = Data("\(Self.esc)[<0;10;5M\(Self.esc)[<0;10;5m\(Self.esc)[<64;10;5M".utf8)
        #expect(filter.filter(press).isEmpty)
        filter.forwardedMouseEvents = .any
        #expect(filter.filter(press) == press)
        // A report split across reads goes out whole and only once.
        #expect(filter.filter(Data("\(Self.esc)[<0;1".utf8)).isEmpty)
        #expect(filter.filter(Data("0;5M".utf8)) == Data("\(Self.esc)[<0;10;5M".utf8))
        // Legacy formats are never forwarded.
        #expect(filter.filter(Data("\(Self.esc)[M !!k".utf8)) == Data("k".utf8))
    }

    @Test(arguments: [
        // (button code, release, events, forwarded)
        (0, false, .x10, true), (0, true, .x10, false), (64, false, .x10, true),
        (0, true, .normal, true), (64, false, .normal, true), (32, false, .normal, false),
        (32, false, .button, true), (35, false, .button, false), (96, false, .button, true),
        (163, false, .button, true),
        (35, false, .any, true), (0, false, .none, false),
    ] as [(Int, Bool, PeerConsoleMouseModeTracker.Events, Bool)])
    func sgrMouseReportsMatchTheHostsTrackingMode(
        button: Int, release: Bool, events: PeerConsoleMouseModeTracker.Events, forwarded: Bool
    ) {
        let parameters = Array("\(button);10;5".utf8)
        #expect(PeerConsoleInputFilter.sgrMouseReport(parameters, release: release, isWanted: events) == forwarded)
    }

    @Test func aSplitLegacyReportKeepsTheEncodingItStartedIn() {
        var filter = PeerConsoleInputFilter()
        filter.legacyMouseUTF8 = true
        #expect(filter.filter(Data([0x1B, 0x5B, 0x4D, 0x20, 0xC2])).isEmpty)
        // The surface is told to leave 1005 before the rest arrives.
        filter.legacyMouseUTF8 = false
        #expect(filter.filter(Data([0xA0, 0x21]) + Data("k".utf8)) == Data("k".utf8))
        // Only that report keeps the old encoding: a raw report after it in
        // the same read is sized as X10.
        filter.legacyMouseUTF8 = true
        #expect(filter.filter(Data([0x1B, 0x5B, 0x4D, 0x20, 0xC2])).isEmpty)
        filter.legacyMouseUTF8 = false
        let rest = Data([0xA0, 0x21, 0x1B, 0x5B, 0x4D, 0x20, 0xC5, 0x21]) + Data("k".utf8)
        #expect(filter.filter(rest) == Data("k".utf8))
    }

    @Test func repliesSplitAcrossReadsAreDroppedAndKeysAroundThemKept() {
        var filter = PeerConsoleInputFilter()
        let first = filter.filter(Data("a\(Self.esc)]11;rgb:00".utf8))
        let second = filter.filter(Data("00/0000/0000\u{07}b\(Self.esc)[?6".utf8))
        let third = filter.filter(Data("2c\(Self.esc)".utf8))
        #expect(first + second + third == Data("ab".utf8))
        // A reply split right after its ESC is still dropped whole.
        #expect(filter.filter(Data("[?62c".utf8)).isEmpty)
        // A lone ESC nothing followed is the Escape key.
        #expect(filter.filter(Data("\(Self.esc)".utf8)).isEmpty)
        #expect(filter.flushAmbiguousPrefix() == Data("\(Self.esc)".utf8))
        #expect(filter.flushAmbiguousPrefix().isEmpty)
    }

    @Test(arguments: ["]", "P", "[", "O", "_"])
    func altKeysThatLookLikeSequenceIntroducersAreReleasedOnTimeout(key: String) {
        var filter = PeerConsoleInputFilter()
        let alt = Data("\(Self.esc)\(key)".utf8)
        #expect(filter.filter(alt).isEmpty)
        #expect(filter.flushAmbiguousPrefix() == alt)
        #expect(filter.filter(Data("x".utf8)) == Data("x".utf8))
    }

    @Test func keysTypedRightAfterAnAltStringIntroducerAreReleasedTogether() {
        var filter = PeerConsoleInputFilter()
        #expect(filter.filter(Data("\(Self.esc)]".utf8)).isEmpty)
        #expect(filter.filter(Data("ab".utf8)).isEmpty)
        #expect(filter.flushAmbiguousPrefix() == Data("\(Self.esc)]ab".utf8))
        // A terminated string in the same window is still a reply.
        #expect(filter.filter(Data("\(Self.esc)]11;rgb:0/0/0\u{07}c".utf8)) == Data("c".utf8))
    }

    @Test func oversizedReplyStringsAreDiscardedUntilTheirTerminator() {
        var filter = PeerConsoleInputFilter()
        // A huge OSC 52 clipboard reply, split across reads, with an ST
        // whose ESC ends one read and whose backslash starts the next.
        let body = Data(repeating: UInt8(ascii: "A"), count: 200 * 1024)
        var kept = filter.filter(Data("k\(Self.esc)]52;c;".utf8) + body.prefix(100 * 1024))
        kept += filter.filter(body.suffix(100 * 1024) + Data("\(Self.esc)".utf8))
        #expect(filter.flushAmbiguousPrefix().isEmpty)
        kept += filter.filter(Data("\\x".utf8))
        #expect(kept == Data("kx".utf8))
    }
}

@Suite struct PeerConsoleMouseModeTrackerTests {
    @Test func aSnapshotWithSeveralModesOfAGroupSetLeavesThemUnknownUntilLiveOutputSettlesThem() {
        var tracker = PeerConsoleMouseModeTracker()
        // Ghostty serializes set modes in fixed order, so this could have
        // been 1006 then 1005 (UTF-8 active) as easily as the reverse.
        tracker.observeSnapshot(Data("\u{1B}c\u{1B}[?1000h\u{1B}[?1005h\u{1B}[?1006h".utf8))
        #expect(!tracker.hostWantsSGRMouse)
        let live = tracker.observe(Data("\u{1B}[?1006h".utf8))
        #expect(live && tracker.hostWantsSGRMouse)
        // RIS clears every mode, which is a known state again.
        tracker.observeSnapshot(Data("\u{1B}c\u{1B}[?1005h\u{1B}[?1006h".utf8))
        _ = tracker.observe(Data("\u{1B}c".utf8))
        #expect(tracker.formatKnown && tracker.hostFormat == .x10)
        // The same holds for event modes: 1003 then 1000 replays as 1000, 1003.
        tracker.observeSnapshot(Data("\u{1B}c\u{1B}[?1000h\u{1B}[?1003h\u{1B}[?1006h".utf8))
        #expect(!tracker.hostWantsSGRMouse)
        let liveEvents = tracker.observe(Data("\u{1B}[?1000h".utf8))
        #expect(liveEvents && tracker.hostWantsSGRMouse)
        // A snapshot with a single format set is unambiguous.
        tracker.observeSnapshot(Data("\u{1B}c\u{1B}[?1000h\u{1B}[?1006h".utf8))
        #expect(tracker.hostWantsSGRMouse)
    }

    @Test func sgrIsForcedRightAfterEachFormatChangeInsideAChunk() {
        var tracker = PeerConsoleMouseModeTracker()
        let sgr = "\u{1B}[?1006h"
        let output = tracker.forcingSGR(Data("a\u{1B}[?1005hbig tail\u{1B}cb\u{1B}[?25lc".utf8))
        #expect(output == Data("a\u{1B}[?1005h\(sgr)big tail\u{1B}c\(sgr)b\u{1B}[?25lc".utf8))
        #expect(tracker.hostFormat == .x10)
        let unchanged = Data("plain\u{1B}[?2004h".utf8)
        let passedThrough = tracker.forcingSGR(unchanged)
        #expect(passedThrough == unchanged)
    }

    @Test func followsTheHostsMouseFormatAcrossSplitsAndResets() {
        var tracker = PeerConsoleMouseModeTracker()
        func observe(_ output: String) -> Bool { tracker.observe(Data(output.utf8)) }
        #expect(tracker.hostFormat == .x10)
        #expect(!observe("\u{1B}[?1000;10"))
        #expect(observe("06h text"))
        #expect(tracker.hostFormat == .sgr)
        // Unrelated or malformed modes are not format changes.
        #expect(!observe("\u{1B}[?2004h\u{1B}[?10060l\u{1B}[1006l"))
        #expect(tracker.hostFormat == .sgr)
        #expect(observe("\u{1B}[?1015h"))
        #expect(tracker.hostFormat == .urxvt)
        // As in Ghostty, resetting any format mode falls back to X10.
        #expect(observe("\u{1B}[?1006l"))
        #expect(tracker.hostFormat == .x10)
        #expect(observe("\u{1B}c"))
        #expect(tracker.hostFormat == .x10)
        // A combined mode change far longer than any fixed buffer.
        let long = String(repeating: "1000;", count: 30) + "1006h"
        #expect(observe("\u{1B}[?\(long)"))
        #expect(tracker.hostFormat == .sgr)
        // Every recognized parameter counts, however many come first.
        #expect(observe("\u{1B}[?" + String(repeating: "1005;", count: 9) + "1006l"))
        #expect(tracker.hostFormat == .x10)
        // Save and restore around a temporary change.
        #expect(observe("\u{1B}[?1006h\u{1B}[?1006s\u{1B}[?1006l"))
        #expect(tracker.hostFormat == .x10)
        #expect(observe("\u{1B}[?1006r"))
        #expect(tracker.hostFormat == .sgr)
        #expect(observe("\u{1B}[?1005s\u{1B}[?1005h"))
        #expect(tracker.hostFormat == .utf8)
        #expect(observe("\u{1B}[?1005r"))
        #expect(tracker.hostFormat == .x10)
        // Parameters are numbers: zero padding names the same mode, and
        // values past any mode number never match one.
        #expect(observe("\u{1B}[?01006h"))
        #expect(tracker.hostFormat == .sgr)
        #expect(observe("\u{1B}[?0001006l"))
        #expect(tracker.hostFormat == .x10)
        #expect(!observe("\u{1B}[?99991006h\u{1B}[?1006000000h"))
        #expect(tracker.hostFormat == .x10)
        // Embedded C0 controls and DEL do not end a sequence; CAN does.
        #expect(observe("\u{1B}[?1005\u{07}h"))
        #expect(tracker.hostFormat == .utf8)
        #expect(observe("\u{1B}[?10\u{7F}06h"))
        #expect(tracker.hostFormat == .sgr)
        #expect(!observe("\u{1B}[?1005\u{18}h"))
        #expect(tracker.hostFormat == .sgr)
        // Event modes follow the same rules in their own group.
        #expect(observe("\u{1B}[?1002h"))
        #expect(tracker.hostEvents == .button)
        #expect(observe("\u{1B}[?1000l"))
        #expect(tracker.hostEvents == .none)
        // A mode saved while another format was selected is still saved set.
        #expect(observe("\u{1B}[?1006h\u{1B}[?1015h\u{1B}[?1006s\u{1B}[?1006l"))
        #expect(tracker.hostFormat == .x10)
        #expect(observe("\u{1B}[?1006r"))
        #expect(tracker.hostFormat == .sgr)
    }
}

@Suite struct PeerConsoleStreamOrderTests {
    @Test func gapRequestsOneResyncAndOutputWaitsForTheNextSnapshot() {
        var order = PeerConsoleStreamOrder()
        #expect(order.output(sequence: 0) == .drop)
        order.snapshot(sequence: 4)
        #expect(order.output(sequence: 5) == .write)
        #expect(order.output(sequence: 7) == .resync)
        #expect(order.output(sequence: 8) == .drop)
        order.snapshot(sequence: 9)
        #expect(order.output(sequence: 10) == .write)
    }
}

@Suite struct PeerConsoleWriteGateTests {
    @Test func bytesWaitUntilTheSurfaceCoversTheHostGrid() {
        var gate = PeerConsoleWriteGate()
        // Nothing is held before the first snapshot, so no fallback is armed.
        #expect(gate.fallback() == nil)
        #expect(gate.output(Data("stale".utf8)) == .hold(armFallback: true))
        // A snapshot supersedes held output and starts a new hold.
        #expect(gate.snapshot(Data("S".utf8)) == .hold(armFallback: true))
        #expect(gate.output(Data("o".utf8)) == .hold(armFallback: false))
        #expect(gate.gridChanged(surfaceFits: false) == nil)
        #expect(gate.gridChanged(surfaceFits: true) == Data("So".utf8))
        #expect(gate.fallback() == nil)
        #expect(gate.output(Data("live".utf8)) == .write(Data("live".utf8)))
        _ = gate.gridChanged(surfaceFits: false)
        #expect(gate.output(Data(count: PeerConsoleWriteGate.maxHeldBytes + 1)) == .resync)
        #expect(gate.gridChanged(surfaceFits: true) == nil)
    }

    @Test func theLargestCaptureWithItsResetPrefixIsHeldNotResynced() {
        var gate = PeerConsoleWriteGate()
        let snapshot = PeerConsoleViewer.resetBeforeSnapshot + Data(count: ZmxIPC.maxPayloadLength)
        #expect(gate.snapshot(snapshot) == .hold(armFallback: true))
    }

    @Test func fallbackReleasesHeldBytesForASurfaceThatNeverFits() {
        var gate = PeerConsoleWriteGate()
        #expect(gate.snapshot(Data("late".utf8)) == .hold(armFallback: true))
        #expect(gate.fallback() == Data("late".utf8))
        #expect(gate.output(Data("next".utf8)) == .write(Data("next".utf8)))
    }
}

@Suite struct PeerConsoleInputRelayTests {
    private func control(_ owner: PeerConsoleControl.Owner, _ generation: Int) -> PeerConsoleControl {
        PeerConsoleControl(owner: owner, generation: generation, change: .current)
    }

    @Test func onlyTheLeaseHolderRelaysFilteredGenerationStampedInput() {
        var relay = PeerConsoleInputRelay()
        let reply = Data("\u{1B}[?62c".utf8)
        for owner in [PeerConsoleControl.Owner.host, .anotherPeer] {
            #expect(relay.relay(Data("x".utf8), attachmentId: "a", control: control(owner, 1)).isEmpty)
        }
        #expect(relay.relay(Data("ls".utf8) + reply, attachmentId: "a", control: control(.you, 3)) == [
            .input(attachmentId: "a", generation: 3, sequence: 1, data: Data("ls".utf8)),
        ])
        #expect(relay.relay(reply, attachmentId: "a", control: control(.you, 3)).isEmpty)
        // A reply that starts in view mode and ends after control is
        // granted is still dropped whole.
        #expect(relay.relay(Data("\u{1B}[".utf8), attachmentId: "a", control: control(.host, 4)).isEmpty)
        #expect(relay.relay(Data("?62c".utf8), attachmentId: "a", control: control(.you, 5)).isEmpty)
        // A reply that starts in view mode and keeps streaming after a grant
        // keeps its view-mode lease, so the timeout cannot release it.
        #expect(relay.relay(Data("\u{1B}]11;rgb".utf8), attachmentId: "a", control: control(.host, 4)).isEmpty)
        #expect(relay.relay(Data(":00/".utf8), attachmentId: "a", control: control(.you, 5)).isEmpty)
        #expect(relay.flushAmbiguousPrefix(attachmentId: "a", control: control(.you, 5)).isEmpty)
        // A key split across reads does not complete under a newer lease.
        #expect(relay.relay(Data("\u{1B}[1;".utf8), attachmentId: "a", control: control(.you, 5)).isEmpty)
        #expect(relay.relay(Data("5C".utf8), attachmentId: "a", control: control(.you, 6)).isEmpty)
        // A held ESC is released only under the lease it was held under.
        let esc = Data("\u{1B}".utf8)
        #expect(relay.relay(esc, attachmentId: "a", control: control(.host, 4)).isEmpty)
        #expect(relay.flushAmbiguousPrefix(attachmentId: "a", control: control(.you, 5)).isEmpty)
        #expect(relay.relay(esc, attachmentId: "a", control: control(.you, 5)).isEmpty)
        #expect(relay.flushAmbiguousPrefix(attachmentId: "a", control: control(.you, 7)).isEmpty)
        #expect(relay.relay(esc, attachmentId: "a", control: control(.you, 3)).isEmpty)
        #expect(relay.flushAmbiguousPrefix(attachmentId: "a", control: control(.you, 3)) == [
            .input(attachmentId: "a", generation: 3, sequence: 2, data: esc),
        ])

        let paste = Data(repeating: 0x61, count: PeerConsoleInputRelay.maxChunk + 1)
        let chunks = relay.relay(paste, attachmentId: "a", control: control(.you, 3))
        #expect(chunks == [
            .input(attachmentId: "a", generation: 3, sequence: 3, data: paste.prefix(PeerConsoleInputRelay.maxChunk)),
            .input(attachmentId: "a", generation: 3, sequence: 4, data: paste.suffix(1)),
        ])
    }

    @Test func forwardingFollowsAcceptedOutputEvenBeforeItReachesTheSurface() {
        var relay = PeerConsoleInputRelay()
        let lease = PeerConsoleControl(owner: .you, generation: 1, change: .current)
        let click = Data("\u{1B}[<0;10;5M".utf8)
        relay.observeHostOutput(Data("\u{1B}[?1000;1006h".utf8))
        #expect(relay.relay(click, attachmentId: "a", control: lease).count == 1)
        // The host turns SGR off; the bytes may still be held by the write
        // gate, but forwarding already stops.
        relay.observeHostOutput(Data("\u{1B}[?1006l".utf8))
        #expect(relay.relay(click, attachmentId: "a", control: lease).isEmpty)
        // Likewise when it stops wanting mouse events while keeping SGR.
        relay.observeHostOutput(Data("\u{1B}[?1006h".utf8))
        #expect(relay.relay(click, attachmentId: "a", control: lease).count == 1)
        relay.observeHostOutput(Data("\u{1B}[?1000l".utf8))
        #expect(relay.relay(click, attachmentId: "a", control: lease).isEmpty)
        // A gap in the output stops forwarding until the snapshot rebuilds
        // the modes the missing bytes may have changed.
        relay.observeHostOutput(Data("\u{1B}[?1000h".utf8))
        relay.forgetHostModes()
        #expect(relay.relay(click, attachmentId: "a", control: lease).isEmpty)
        relay.observeHostOutput(Data("\u{1B}c\u{1B}[?1000h\u{1B}[?1006h".utf8), isSnapshot: true)
        #expect(relay.relay(click, attachmentId: "a", control: lease).count == 1)
        // A legacy report the surface emits before the override lands is
        // dropped whole, sized by the format the surface was just told.
        _ = relay.prepareForSurface(Data("\u{1B}[?1005h".utf8))
        let utf8Report = Data([0x1B, 0x5B, 0x4D, 0x20, 0xC2, 0xA0, 0x21]) + Data("k".utf8)
        #expect(relay.relay(utf8Report, attachmentId: "a", control: lease).compactMap(\.inputData) == [Data("k".utf8)])
        _ = relay.prepareForSurface(Data("\u{1B}[?1005l".utf8))
        let x10Report = Data([0x1B, 0x5B, 0x4D, 0x20, 0xC2, 0xA0]) + Data("k".utf8)
        #expect(relay.relay(x10Report, attachmentId: "a", control: lease).compactMap(\.inputData) == [Data("k".utf8)])
        // The surface still gets its SGR override when the bytes arrive.
        #expect(relay.prepareForSurface(Data("\u{1B}[?1006l".utf8)) == Data("\u{1B}[?1006l\u{1B}[?1006h".utf8))
    }
}

@Suite struct PeerConsoleBridgeTests {
    @Test func bytesQueuedBeforeConnectArriveInOrderAndInputComesBack() async throws {
        let input = ZmxEventLog<Data>()
        let bridge = try PeerConsoleBridge { input.append($0) }
        bridge.write(Data("snap".utf8))
        bridge.write(Data("shot".utf8))

        let socket = try ZmxIPCSocket.connect(path: bridge.socketPath)
        var received = Data()
        while received.count < 8, let chunk = socket.read(), !chunk.isEmpty { received += chunk }
        #expect(received == Data("snapshot".utf8))
        // Single use: the path is gone once the surface connected.
        try await eventually("socket unlinked") { !FileManager.default.fileExists(atPath: bridge.socketPath) }

        socket.write(Data("keys".utf8))
        try await eventually("input") { input.all.reduce(Data(), +) == Data("keys".utf8) }

        bridge.close()
        #expect(socket.read() == Data())
    }

    @Test func aSurfaceThatStopsDrainingIsBoundedThenRecovers() async throws {
        let bridge = try PeerConsoleBridge(maxPendingBytes: 256 * 1024) { _ in }
        defer { bridge.close() }
        let socket = try ZmxIPCSocket.connect(path: bridge.socketPath)
        // Nobody reads: the socket buffer fills, then the bridge's queue.
        let chunk = Data(repeating: 0x61, count: 64 * 1024)
        var accepted = 0
        while accepted < 64, bridge.write(chunk) { accepted += 1 }
        #expect(accepted < 64)

        let drain = Task.detached { while let data = socket.read(), !data.isEmpty {} }
        defer { drain.cancel() }
        try await eventually("bridge drains") { bridge.write(Data("x".utf8)) }
    }
}

@MainActor
@Suite struct NativePeerConsolesTests {
    @Test func listsAreRequestedFromCapablePeersAndKeptOnlyWhileOnline() {
        var sent: [(String, RemoteClientMessage)] = []
        let consoles = NativePeerConsoles(
            send: { sent.append(($0, $1)) },
            supportsConsoles: { $0 == "srv-new" },
            makeSurface: { _, _, _ in throw CancellationError() }
        )
        let summary = PeerConsoleSummary(
            consoleId: "c", title: "zsh", worktreeId: nil, projectId: nil,
            projectName: nil, worktreeName: nil, rows: 24, columns: 80)

        consoles.peersChanged(online: ["srv-new", "srv-old"])
        #expect(sent.map(\.0) == ["srv-new"])
        #expect(sent.map(\.1) == [.console(.list)])

        consoles.receive(serverId: "srv-new", .list(consoles: [summary]))
        consoles.receive(serverId: "srv-gone", .list(consoles: [summary]))
        #expect(consoles.consoles == ["srv-new": [summary]])

        consoles.peersChanged(online: ["srv-old"])
        #expect(consoles.consoles.isEmpty)
        // Only newly online peers are asked again.
        consoles.peersChanged(online: ["srv-old", "srv-new"])
        #expect(sent.count == 2)
    }
}

private extension PeerConsoleRequest {
    var inputData: Data? {
        if case .input(_, _, _, let data) = self { data } else { nil }
    }
}
