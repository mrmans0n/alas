import Foundation
import Testing
@testable import Alas

// MARK: - Outbox

@Suite struct PeerConsoleOutboxTests {
    private let limits = PeerConsoleOutbox.Limits(
        maxPendingBytes: 8, maxPendingMessages: 4, maxInFlightBytes: 3, maxChunkBytes: 4)

    @Test func outputIsSequencedAfterTheSnapshotAndHeldByInFlightCredit() {
        var outbox = PeerConsoleOutbox(limits: limits)
        #expect(outbox.output(Data("pre".utf8)).isEmpty)
        #expect(outbox.snapshot(Data("S".utf8)) == [.snapshot(sequence: 0, reason: .initial, data: Data("S".utf8))])
        // One byte in flight leaves room for one coalesced chunk.
        #expect(outbox.output(Data("ab".utf8)) == [.output(sequence: 1, data: Data("ab".utf8))])
        #expect(outbox.output(Data("cd".utf8)).isEmpty)
        #expect(outbox.output(Data("e".utf8)).isEmpty)
        #expect(outbox.delivered(bytes: 3) == [.output(sequence: 2, data: Data("cde".utf8))])
    }

    @Test func overflowDiscardsDeltasAndResyncsOnceThePeerDrains() {
        var outbox = PeerConsoleOutbox(limits: limits)
        _ = outbox.snapshot(Data("SSSS".utf8))
        #expect(outbox.output(Data("12345".utf8)).isEmpty)
        // Over the pending limit: deltas dropped, capture waits for credit.
        #expect(outbox.output(Data("6789".utf8)).isEmpty)
        #expect(outbox.output(Data("x".utf8)).isEmpty)
        #expect(outbox.requestResync(.requested).isEmpty)
        #expect(outbox.delivered(bytes: 4) == [.requestCapture])
        #expect(outbox.requestResync(.requested).isEmpty)
        #expect(outbox.output(Data("y".utf8)).isEmpty)
        #expect(outbox.snapshot(Data("T".utf8)) == [.snapshot(sequence: 1, reason: .peerBackpressure, data: Data("T".utf8))])
        #expect(outbox.delivered(bytes: 1).isEmpty)
        #expect(outbox.output(Data("z".utf8)) == [.output(sequence: 2, data: Data("z".utf8))])
    }
}

// MARK: - Leases

@Suite struct PeerConsoleLeaseBookTests {
    @Test func leaseIsExclusiveAndEveryChangeInvalidatesOlderGenerations() {
        var book = PeerConsoleLeaseBook()
        let first = book.take("c", by: "a")
        #expect(first == 1)
        #expect(book.take("c", by: "a") == 1)
        #expect(book.take("c", by: "b") == nil)
        #expect(book.release("c", by: "b") == nil)
        #expect(book.accepts("c", from: "a", generation: 1))
        #expect(!book.accepts("c", from: "b", generation: 1))

        let reclaimed = book.reclaim("c")
        #expect(reclaimed?.attachmentId == "a" && reclaimed?.generation == 2)
        #expect(!book.accepts("c", from: "a", generation: 1))
        #expect(book.reclaim("c") == nil)

        #expect(book.take("c", by: "b") == 3)
        #expect(book.release("c", by: "b") == 4)
        #expect(!book.accepts("c", from: "b", generation: 3))
    }
}

// MARK: - Host

@MainActor
@Suite struct PeerConsoleHostTests {
    /// One fake peer connection. Write completions fire asynchronously, as
    /// NWConnection's do.
    private final class FakePeer: @unchecked Sendable {
        let events = ZmxEventLog<PeerConsoleEvent>()
        lazy var link = PeerConsoleLink(peerName: "Peer") { [events] event, onWritten in
            events.append(event)
            DispatchQueue.global().async(execute: onWritten)
        }

        func control(_ attachmentId: String) -> [PeerConsoleControl] {
            events.all.compactMap {
                if case .control(attachmentId, let control) = $0 { control } else { nil }
            }
        }

        func acks(_ attachmentId: String) -> [Bool] {
            events.all.compactMap {
                if case .inputAck(attachmentId, _, let accepted) = $0 { accepted } else { nil }
            }
        }
    }

    @MainActor
    private final class Fixture {
        var sockets: [ZmxSocketPair] = []
        var connectCount = 0
        var suppressed: [Bool] = []
        var terminated: [String] = []
        var known = ["c"]
        lazy var host = PeerConsoleHost(environment: .init(
            consoles: { [] },
            resolve: { [unowned self] id in
                known.contains(id) ? PeerConsoleTarget(consoleId: id, socketPath: "/unused", rows: 40, columns: 120) : nil
            },
            setLocalInputSuppressed: { [unowned self] _, on in suppressed.append(on) },
            terminate: { [unowned self] id in
                terminated.append(id)
                known.removeAll { $0 == id }
            },
            // The host connects on the main actor.
            connect: { [unowned self] _ in try MainActor.assumeIsolated { try self.makeSocket() } }
        ))

        private func makeSocket() throws -> ZmxIPCSocket {
            connectCount += 1
            let pair = try ZmxSocketPair()
            sockets.append(pair)
            return ZmxIPCSocket(fd: pair.client)
        }
    }

    @Test func unavailableConsoleIsRefusedBeforeConnecting() {
        let fixture = Fixture()
        let peer = FakePeer()
        fixture.host.handle(.attach(consoleId: "gone", attachmentId: "a", scrollbackRows: 0), from: peer.link)
        #expect(peer.events.all == [.detached(attachmentId: "a", reason: .unavailable)])
        #expect(fixture.connectCount == 0)
    }

    @Test func attachmentsPerPeerAreBoundedBeforeAnySocketOpens() {
        let fixture = Fixture()
        let peer = FakePeer()
        for index in 0...PeerConsoleHost.maxAttachmentsPerLink {
            fixture.host.handle(.attach(consoleId: "c", attachmentId: "a\(index)", scrollbackRows: 0), from: peer.link)
        }
        let over = "a\(PeerConsoleHost.maxAttachmentsPerLink)"
        #expect(peer.events.all.last == .detached(attachmentId: over, reason: .limitReached))
        #expect(fixture.connectCount == PeerConsoleHost.maxAttachmentsPerLink)
    }

    @Test func snapshotPrecedesLiveOutputAndTargetExitDetaches() async throws {
        let fixture = Fixture()
        let peer = FakePeer()
        fixture.host.handle(.attach(consoleId: "c", attachmentId: "a", scrollbackRows: 99), from: peer.link)
        let daemon = try #require(fixture.sockets.first)
        daemon.write(ZmxIPC.encode(.output, Data("pre".utf8)))
        daemon.write(ZmxIPC.encode(.capture, Data("S".utf8)) + ZmxIPC.encode(.output, Data("o".utf8)))
        try await eventually("snapshot and output") { peer.events.all.count == 3 }
        daemon.closeDaemonEnd()
        try await eventually("detached") { peer.events.all.count == 4 }
        #expect(peer.events.all == [
            .attached(attachmentId: "a", rows: 40, columns: 120,
                      control: PeerConsoleControl(owner: .host, generation: 0, change: .current)),
            .snapshot(attachmentId: "a", sequence: 0, reason: .initial, data: Data("S".utf8)),
            .output(attachmentId: "a", sequence: 1, data: Data("o".utf8)),
            .detached(attachmentId: "a", reason: .targetExited),
        ])
    }

    @Test func inputTheConsoleCannotTakeEndsControlVisibly() {
        let fixture = Fixture()
        let peer = FakePeer()
        fixture.host.handle(.attach(consoleId: "c", attachmentId: "a", scrollbackRows: 0), from: peer.link)
        fixture.host.handle(.takeControl(attachmentId: "a"), from: peer.link)
        // The daemon end never reads, so the client's input queue fills.
        let paste = Data(count: PeerConsoleHost.maxInputBytes)
        for sequence in 1...8 where !peer.acks("a").contains(false) {
            fixture.host.handle(.input(attachmentId: "a", generation: 1, sequence: sequence, data: paste), from: peer.link)
        }
        #expect(peer.acks("a").last == false)
        #expect(peer.control("a").last == PeerConsoleControl(owner: .host, generation: 2, change: .revoked))
        #expect(fixture.suppressed == [true, false])
        #expect(fixture.host.controllers.isEmpty)
    }

    @Test func terminateDetachesEveryViewerClosesTheConsoleAndRelists() {
        let fixture = Fixture()
        let owner = FakePeer()
        let other = FakePeer()
        fixture.host.handle(.attach(consoleId: "c", attachmentId: "a", scrollbackRows: 0), from: owner.link)
        fixture.host.handle(.attach(consoleId: "c", attachmentId: "b", scrollbackRows: 0), from: other.link)
        fixture.host.handle(.takeControl(attachmentId: "a"), from: owner.link)

        // Terminating needs no attachment or lease.
        let requester = FakePeer()
        fixture.host.handle(.terminate(consoleId: "c"), from: requester.link)
        #expect(owner.events.all.last == .detached(attachmentId: "a", reason: .terminated))
        #expect(other.events.all.last == .detached(attachmentId: "b", reason: .terminated))
        #expect(fixture.terminated == ["c"])
        #expect(requester.events.all == [.list(consoles: [])])
        #expect(fixture.suppressed == [true, false])
        #expect(fixture.host.controllers.isEmpty)
    }

    @Test func terminatingAnUnknownConsoleIsRejected() {
        let fixture = Fixture()
        let viewer = FakePeer()
        fixture.host.handle(.attach(consoleId: "c", attachmentId: "a", scrollbackRows: 0), from: viewer.link)
        fixture.host.handle(.terminate(consoleId: "gone"), from: viewer.link)
        #expect(fixture.terminated.isEmpty)
        #expect(viewer.events.all.count == 1)
    }

    @Test func controlIsExclusiveGenerationScopedAndEnforcedByTheHost() async throws {
        let fixture = Fixture()
        let owner = FakePeer()
        let other = FakePeer()
        fixture.host.handle(.attach(consoleId: "c", attachmentId: "a", scrollbackRows: 0), from: owner.link)
        fixture.host.handle(.attach(consoleId: "c", attachmentId: "b", scrollbackRows: 0), from: other.link)

        fixture.host.handle(.takeControl(attachmentId: "a"), from: owner.link)
        fixture.host.handle(.takeControl(attachmentId: "b"), from: other.link)
        // Another link cannot act on an attachment it does not own.
        fixture.host.handle(.takeControl(attachmentId: "a"), from: other.link)
        #expect(owner.control("a") == [PeerConsoleControl(owner: .you, generation: 1, change: .granted)])
        #expect(other.control("b") == [
            PeerConsoleControl(owner: .anotherPeer, generation: 1, change: .granted),
            PeerConsoleControl(owner: .anotherPeer, generation: 1, change: .denied),
        ])
        #expect(fixture.host.controllers == ["c": "Peer"])
        #expect(fixture.suppressed == [true])

        let input = Data("ls\r".utf8)
        fixture.host.handle(.input(attachmentId: "a", generation: 1, sequence: 1, data: input), from: owner.link)
        fixture.host.handle(.input(attachmentId: "b", generation: 1, sequence: 1, data: input), from: other.link)
        var decoder = ZmxFrameDecoder()
        let frames = try fixture.sockets[0].readFrames(&decoder, count: 2)
        #expect(frames.map(\.tag) == [ZmxIPC.Tag.capture.rawValue, ZmxIPC.Tag.send.rawValue])
        #expect(frames.last?.payload == input)

        fixture.host.reclaim("c")
        fixture.host.handle(.input(attachmentId: "a", generation: 1, sequence: 2, data: input), from: owner.link)
        #expect(owner.acks("a") == [true, false])
        #expect(other.acks("b") == [false])
        #expect(owner.control("a").last == PeerConsoleControl(owner: .host, generation: 2, change: .reclaimed))
        #expect(fixture.suppressed == [true, false])

        // Losing the connection revokes a re-taken lease and restores input.
        fixture.host.handle(.takeControl(attachmentId: "a"), from: owner.link)
        fixture.host.close(owner.link)
        #expect(other.control("b").last == PeerConsoleControl(owner: .host, generation: 4, change: .revoked))
        #expect(fixture.suppressed == [true, false, true, false])
        #expect(fixture.host.controllers.isEmpty)
        try await eventually("detached client closes its socket") {
            (try? fixture.sockets[0].readFrames(&decoder, count: 1)) == nil
        }
    }
}
