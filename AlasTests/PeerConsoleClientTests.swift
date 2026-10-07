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
    func keyboardInputPassesThrough(input: String) {
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
        "\(esc)[<0;10;5M\(esc)[<0;10;5m",                     // SGR mouse
        "\(esc)[M !!",                                        // X10 mouse
        "\(esc)[8;40;120t",                                   // window size report
    ])
    func terminalRepliesAreDropped(reply: String) {
        var filter = PeerConsoleInputFilter()
        #expect(filter.filter(Data(reply.utf8)).isEmpty)
    }

    @Test func repliesSplitAcrossReadsAreDroppedAndKeysAroundThemKept() {
        var filter = PeerConsoleInputFilter()
        let first = filter.filter(Data("a\(Self.esc)]11;rgb:00".utf8))
        let second = filter.filter(Data("00/0000/0000\u{07}b\(Self.esc)[?6".utf8))
        let third = filter.filter(Data("2c\(Self.esc)".utf8))
        #expect(first + second + third == Data("ab\(Self.esc)".utf8))
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
        #expect(gate.output(Data("stale".utf8)) == .hold)
        // A snapshot supersedes held output.
        #expect(gate.snapshot(Data("S".utf8)) == .hold)
        #expect(gate.output(Data("o".utf8)) == .hold)
        #expect(gate.gridChanged(surfaceFits: false) == nil)
        #expect(gate.gridChanged(surfaceFits: true) == Data("So".utf8))
        #expect(gate.output(Data("live".utf8)) == .write(Data("live".utf8)))
        _ = gate.gridChanged(surfaceFits: false)
        #expect(gate.output(Data(count: PeerConsoleWriteGate.maxHeldBytes + 1)) == .resync)
        #expect(gate.gridChanged(surfaceFits: true) == nil)
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

        let paste = Data(repeating: 0x61, count: PeerConsoleInputRelay.maxChunk + 1)
        let chunks = relay.relay(paste, attachmentId: "a", control: control(.you, 3))
        #expect(chunks == [
            .input(attachmentId: "a", generation: 3, sequence: 2, data: paste.prefix(PeerConsoleInputRelay.maxChunk)),
            .input(attachmentId: "a", generation: 3, sequence: 3, data: paste.suffix(1)),
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
