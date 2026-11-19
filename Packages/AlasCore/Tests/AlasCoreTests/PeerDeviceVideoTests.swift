import AlasRemoteKit
import Foundation
import Synchronization
import Testing
@testable import AlasHostCore

struct PeerDeviceVideoTests {
    @Test func aFrameUsesBigEndianFieldsAndPreservesMicrosecondPTS() {
        let frame = PeerDeviceVideoPacket.frame(generation: 42, pts: 1_000_000, keyFrame: true, bytes: Data([0x65]))
        let binary = Data([
            1, 3, 1, 0,
            0, 0, 0, 0, 0, 0, 0, 42,
            0, 0, 0, 1,
            0, 0, 0, 0, 0, 0x0F, 0x42, 0x40,
            0x65,
        ])
        #expect(frame.encoded() == binary)
        #expect(PeerDeviceVideoPacket(binary: binary) == frame)
    }

    @Test(arguments: [0, 1, 3, 15, 23, 24, 25])
    func malformedPacketsAreRefused(change: Int) throws {
        var bytes = try #require(Self.key(1).encoded())
        if change < bytes.count { bytes[change] = .max } else { bytes.append(0) }
        if change == 23 {
            bytes.removeLast(2)
        } else if change == 24 {
            bytes.removeLast()
        }
        #expect(PeerDeviceVideoPacket(binary: bytes) == nil)
    }

    @Test @MainActor func rotationDropsOldBacklogForOnlyTheSlowViewer() async throws {
        let instant = ContinuousClock.now
        let fanout = PeerDeviceVideoFanout(now: { instant })
        let fast = Sink(fanout)
        let slow = Sink(fanout)
        let first = [Self.format(1), Self.config(1), Self.key(1), Self.delta(1)]
        let second = [Self.format(2), Self.config(2), Self.key(2), Self.delta(2)]
        for packet in first + second {
            fanout.publish(packet)
            try await fast.drain()
        }
        #expect(fast.packets == first + second)
        #expect(slow.packets == [first[0]])
        try await slow.drain()
        #expect(slow.packets == [first[0]] + second)
    }

    @Test(arguments: [false, true]) @MainActor
    func overflowSkipsDependentFramesUntilTheNextKeyframe(expireByAge: Bool) async throws {
        let clock = TestClock()
        let fanout = PeerDeviceVideoFanout(now: { clock.now })
        let slow = Sink(fanout)
        let format = Self.format(1)
        let config = Self.config(1)
        fanout.publish(format)
        fanout.publish(config)
        fanout.publish(Self.key(1))
        if expireByAge {
            clock.now = clock.now + .milliseconds(501)
            fanout.expire()
        } else {
            let largeDelta = PeerDeviceVideoPacket.frame(
                generation: 1, pts: 20, keyFrame: false, bytes: Data(repeating: 0, count: 400 * 1024)
            )
            fanout.publish(largeDelta)
            fanout.publish(largeDelta)
        }
        try await slow.drain()
        fanout.publish(Self.delta(1))
        try await slow.drain()
        #expect(slow.packets == [format])

        let key = Self.key(1, pts: 30)
        fanout.publish(key)
        try await slow.drain()
        #expect(slow.packets == [format, config, key])
    }

    @Test @MainActor func idleLateJoinReplaysACompleteGOPButNotAPartialOne() async throws {
        let clock = TestClock()
        let fanout = PeerDeviceVideoFanout(now: { clock.now })
        let gop = [Self.format(1), Self.config(1), Self.key(1), Self.delta(1)]
        for packet in gop { fanout.publish(packet) }
        clock.now = clock.now + .seconds(60)
        let idle = Sink(fanout)
        try await idle.drain()
        #expect(idle.packets == gop)

        fanout.publish(.frame(generation: 1, pts: 3, keyFrame: false, bytes: Data(repeating: 1, count: 512 * 1024)))
        let late = Sink(fanout)
        try await late.drain()
        fanout.publish(Self.delta(1))
        try await late.drain()
        #expect(late.packets == [gop[0]])
        clock.now = clock.now + .seconds(5)
        fanout.expire()
        #expect(late.closed)
    }

    @Test @MainActor func aNewFanoutKeepsConfigFromAnIncompleteSourceGOP() async throws {
        let format = Self.format(1)
        let config = Self.config(1)
        let oversized = PeerDeviceVideoPacket.frame(
            generation: 1, pts: 20, keyFrame: false, bytes: Data(repeating: 0, count: 512 * 1024)
        )
        var source = PeerDeviceVideoBootstrap()
        for packet in [format, config, Self.key(1), oversized] { source.update(packet) }
        let instant = ContinuousClock.now
        let fanout = PeerDeviceVideoFanout(now: { instant })
        let viewer = Sink(fanout)
        source.replay { fanout.publish($0) }
        try await viewer.drain()
        #expect(viewer.packets == [format])
        let key = Self.key(1, pts: 30)
        fanout.publish(key)
        try await viewer.drain()
        #expect(viewer.packets == [format, config, key])
    }

    @Test @MainActor func aStuckWriteClosesWithoutExpiringAnIdleViewer() async throws {
        let clock = TestClock()
        let fanout = PeerDeviceVideoFanout(now: { clock.now })
        let stuck = Sink(fanout)
        let idle = Sink(fanout)
        for packet in [Self.format(1), Self.config(1), Self.key(1)] { fanout.publish(packet) }
        try await idle.drain()
        clock.now += .seconds(5)
        fanout.expire()
        #expect(stuck.closed)
        #expect(!idle.closed)
    }

    private static func format(_ generation: UInt64) -> PeerDeviceVideoPacket {
        .format(generation: generation, width: 720, height: 1600)
    }

    private static func config(_ generation: UInt64) -> PeerDeviceVideoPacket {
        .config(generation: generation, bytes: Data([0x67]))
    }

    private static func key(_ generation: UInt64, pts: UInt64 = 10) -> PeerDeviceVideoPacket {
        .frame(generation: generation, pts: pts, keyFrame: true, bytes: Data([0x65]))
    }

    private static func delta(_ generation: UInt64) -> PeerDeviceVideoPacket {
        .frame(generation: generation, pts: 20, keyFrame: false, bytes: Data([0x41]))
    }

    @MainActor private final class TestClock {
        var now = ContinuousClock.now
    }

    @MainActor private final class Sink {
        struct Delivery: Sendable {
            var bytes: Data
            var finish: @Sendable () -> Void
        }

        private nonisolated let deliveries = Mutex<[Delivery]>([])
        private var received: [PeerDeviceVideoPacket] = []
        var packets: [PeerDeviceVideoPacket] {
            received + deliveries.withLock { $0.compactMap { PeerDeviceVideoPacket(binary: $0.bytes) } }
        }
        private(set) var closed = false

        init(_ fanout: PeerDeviceVideoFanout) {
            fanout.add(id: UUID(), write: { [self] bytes, finish in
                deliveries.withLock { $0.append(Delivery(bytes: bytes, finish: finish)) }
            }, close: { [weak self] in self?.closed = true })
        }

        func drain() async throws {
            while let delivery = deliveries.withLock({ queue in queue.isEmpty ? nil : queue.removeFirst() }) {
                received.append(try #require(PeerDeviceVideoPacket(binary: delivery.bytes)))
                delivery.finish()
                // Completion hops to the main queue before submitting the next write.
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
    }
}
