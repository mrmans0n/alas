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
        "\(esc)[<0;10;5M\(esc)[<0;10;5m",                     // SGR mouse press and release
        "\(esc)[<64;10;5M",                                    // SGR wheel
        "\(esc)[M !!",                                        // X10 mouse
        "\(esc)[M \u{A0}!",                                   // UTF-8/1005 mouse (two-byte column)
        "\(esc)[32;10;5M",                                     // rxvt/1015 mouse
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
    ])
    func terminalRepliesAreDropped(reply: String) {
        var filter = PeerConsoleInputFilter()
        #expect(filter.filter(Data(reply.utf8)).isEmpty)
    }

    @Test(arguments: [
        ([0x1B, 0x5B, 0x4D, 0x20, 0xC0, 0x21], false),       // raw X10, column 160
        ([0x1B, 0x5B, 0x4D, 0x20, 0xC2, 0xA0], false),       // raw X10 whose bytes look like UTF-8
        ([0x1B, 0x5B, 0x4D, 0x20, 0xC2, 0xA0, 0x21], true),  // UTF-8/1005, two-byte column
    ] as [([UInt8], Bool)])
    func mouseCoordinatesFollowTheHostsEncoding(report: [UInt8], utf8: Bool) {
        var filter = PeerConsoleInputFilter()
        filter.utf8MouseCoordinates = utf8
        #expect(filter.filter(Data(report) + Data("k".utf8)) == Data(report) + Data("k".utf8))
        #expect(!filter.hasPending)
    }

    @Test func mouseReportsSplitAcrossReadsGoOutWholeAndOnce() {
        var filter = PeerConsoleInputFilter()
        #expect(filter.filter(Data("\(Self.esc)[<0;1".utf8)).isEmpty)
        #expect(filter.filter(Data("0;5M".utf8)) == Data("\(Self.esc)[<0;10;5M".utf8))
        // A 1005 report split inside a two-byte coordinate.
        filter.utf8MouseCoordinates = true
        #expect(filter.filter(Data([0x1B, 0x5B, 0x4D, 0x20, 0xC2])).isEmpty)
        #expect(filter.filter(Data([0xA0, 0x21])) == Data([0x1B, 0x5B, 0x4D, 0x20, 0xC2, 0xA0, 0x21]))
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
    @Test func followsMode1005AcrossSplitsAndResets() {
        var tracker = PeerConsoleMouseModeTracker()
        tracker.observe(Data("\u{1B}[?1000;10".utf8))
        #expect(!tracker.utf8Coordinates)
        tracker.observe(Data("05h text".utf8))
        #expect(tracker.utf8Coordinates)
        tracker.observe(Data("\u{1B}[?10050l\u{1B}[1005l".utf8))
        #expect(tracker.utf8Coordinates)
        tracker.observe(Data("\u{1B}c".utf8))
        #expect(!tracker.utf8Coordinates)
        tracker.observe(Data("\u{1B}[?1005h\u{1B}[?1005l".utf8))
        #expect(!tracker.utf8Coordinates)
        // A combined mode change far longer than any fixed buffer.
        let long = String(repeating: "1000;", count: 30) + "1005h"
        tracker.observe(Data("\u{1B}[?\(long)".utf8))
        #expect(tracker.utf8Coordinates)
        tracker.observe(Data("\u{1B}[?100500h".utf8))
        #expect(tracker.utf8Coordinates)
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
