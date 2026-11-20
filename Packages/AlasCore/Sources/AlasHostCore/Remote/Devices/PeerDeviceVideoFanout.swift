import AlasRemoteKit
import Foundation

/// One tracked write per viewer. A viewer that drops a frame waits for a new
/// keyframe instead of feeding a broken prediction chain to its decoder.
@MainActor
public final class PeerDeviceVideoFanout {
    private typealias Instant = ContinuousClock.Instant
    private static let pendingAge: Duration = .milliseconds(500)
    private static let progressTimeout: Duration = .seconds(5)

    private struct Pending {
        let data: Data
        let at: Instant
        let format: UInt64?
        let resumesDecoding: Bool
    }

    @MainActor
    private final class Viewer {
        let id: UUID
        let write: @Sendable (Data, @escaping @Sendable () -> Void) -> Void
        let close: @MainActor () -> Void
        var pending: ArraySlice<Pending?> = []
        var bytes = 0
        var sentFormat: UInt64?
        var queuedFormat: UInt64?
        var needsKey = true
        var recoveryWrite: UInt64?
        var recoveringSince: Instant?
        var writingSince: Instant?
        var writeSequence: UInt64 = 0

        init(
            id: UUID, now: Instant, write: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void,
            close: @escaping @MainActor () -> Void
        ) {
            self.id = id
            self.write = write
            self.close = close
            recoveringSince = now
        }

        func fits(_ bytes: Int, count: Int = 1) -> Bool {
            pending.count + count <= 256 && self.bytes + bytes <= PeerDeviceVideoPacket.maxPacketBytes
        }

        func enqueue(_ data: Data, at: Instant, format: UInt64? = nil, resumesDecoding: Bool = false) {
            pending.append(Pending(data: data, at: at, format: format, resumesDecoding: resumesDecoding))
            bytes += data.count
            if let format { queuedFormat = format }
        }

        func next() -> Pending? {
            guard let message = pending.first ?? nil else { return nil }
            pending[pending.startIndex] = nil // Release the buffer even while the slice keeps its storage.
            pending = pending.dropFirst()
            if pending.isEmpty { pending = [] }
            else if pending.startIndex >= 32, pending.startIndex >= pending.count {
                pending = ArraySlice(Array(pending))
            }
            bytes -= message.data.count
            if let format = message.format {
                queuedFormat = nil
                sentFormat = format
            }
            return message
        }

        func recover(at: Instant) {
            pending = []
            bytes = 0
            queuedFormat = nil
            needsKey = true
            recoveryWrite = nil
            if recoveringSince == nil { recoveringSince = at }
        }

        var deadline: Instant? {
            var first = (pending.first ?? nil).map { $0.at + PeerDeviceVideoFanout.pendingAge }
            if let recoveringSince {
                let timeout = recoveringSince + PeerDeviceVideoFanout.progressTimeout
                first = first.map { min($0, timeout) } ?? timeout
            }
            if let writingSince {
                let timeout = writingSince + PeerDeviceVideoFanout.progressTimeout
                first = first.map { min($0, timeout) } ?? timeout
            }
            return first
        }
    }

    private let now: () -> Instant
    private var viewers: [UUID: Viewer] = [:]
    private var bootstrap = PeerDeviceVideoBootstrap()
    private var encodedFormat: (generation: UInt64, data: Data)?
    private var encodedConfig: Data?
    private var timer: Task<Void, Never>?
    private var scheduled: Instant?

    public convenience init() {
        self.init(now: { .now })
    }

    init(now: @escaping () -> ContinuousClock.Instant) {
        self.now = now
    }

    deinit { timer?.cancel() }

    public func add(
        id: UUID, write: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void,
        close: @escaping @MainActor () -> Void
    ) {
        let instant = now()
        let viewer = Viewer(id: id, now: instant, write: write, close: close)
        viewers[id] = viewer
        enqueueFormat(for: viewer, at: instant)
        bootstrap.replay { packet in
            switch packet {
            case .format: break
            case .config: break
            case .frame(_, _, let key, _):
                guard let data = packet.encoded() else { return }
                if key, let encodedConfig {
                    viewer.enqueue(encodedConfig, at: instant)
                    viewer.needsKey = false
                }
                viewer.enqueue(data, at: instant, resumesDecoding: key)
            }
        }
        sendNext(viewer, at: instant)
        scheduleDeadline()
    }

    public func remove(id: UUID) {
        viewers[id] = nil
        scheduleDeadline()
    }

    public func publish(_ packet: PeerDeviceVideoPacket) {
        let instant = now()
        expire(at: instant)
        switch packet {
        case .format:
            bootstrap.update(packet)
            encodedFormat = packet.encoded().map { (packet.generation, $0) }
            encodedConfig = nil
            for viewer in viewers.values {
                viewer.recover(at: instant)
                enqueueFormat(for: viewer, at: instant)
                sendNext(viewer, at: instant)
            }
        case .config:
            guard encodedFormat?.generation == packet.generation else { return scheduleDeadline() }
            bootstrap.update(packet)
            encodedConfig = packet.encoded()
            for viewer in viewers.values {
                viewer.recover(at: instant)
                enqueueFormat(for: viewer, at: instant)
                sendNext(viewer, at: instant)
            }
        case .frame(_, _, let key, _):
            guard encodedFormat?.generation == packet.generation else { return scheduleDeadline() }
            bootstrap.update(packet)
            guard !viewers.isEmpty else { return scheduleDeadline() }
            let data = packet.encoded()
            for viewer in viewers.values {
                guard let data else {
                    viewer.recover(at: instant)
                    continue
                }
                if !viewer.needsKey, !viewer.fits(data.count) {
                    viewer.recover(at: instant)
                }
                let resuming = viewer.needsKey
                if resuming {
                    guard key, let encodedConfig else { continue }
                    enqueueFormat(for: viewer, at: instant)
                    guard viewer.fits(encodedConfig.count + data.count, count: 2) else {
                        sendNext(viewer, at: instant)
                        continue
                    }
                    viewer.enqueue(encodedConfig, at: instant)
                }
                if resuming { viewer.needsKey = false }
                viewer.enqueue(data, at: instant, resumesDecoding: resuming)
                sendNext(viewer, at: instant)
            }
        }
        scheduleDeadline()
    }

    private func enqueueFormat(for viewer: Viewer, at instant: Instant) {
        guard let (generation, data) = encodedFormat,
              viewer.sentFormat != generation, viewer.queuedFormat != generation else { return }
        viewer.enqueue(data, at: instant, format: generation)
    }

    private func sendNext(_ viewer: Viewer, at instant: Instant) {
        guard viewer.writingSince == nil, let message = viewer.next() else { return }
        let id = viewer.id
        viewer.writingSince = instant
        viewer.writeSequence &+= 1
        let sequence = viewer.writeSequence
        if message.resumesDecoding { viewer.recoveryWrite = sequence }
        viewer.write(message.data) { [weak self, weak viewer] in
            DispatchQueue.main.async { [weak self, weak viewer] in
                MainActor.assumeIsolated {
                    guard let self, let viewer, self.viewers[id] === viewer,
                          viewer.writeSequence == sequence, viewer.writingSince != nil else { return }
                    let instant = self.now()
                    viewer.writingSince = nil
                    if viewer.recoveryWrite == sequence {
                        viewer.recoveryWrite = nil
                        viewer.recoveringSince = nil
                    }
                    self.expire(at: instant)
                    if self.viewers[id] === viewer { self.sendNext(viewer, at: instant) }
                    self.scheduleDeadline()
                }
            }
        }
    }

    func expire() {
        expire(at: now())
        scheduleDeadline()
    }

    private func expire(at instant: Instant) {
        for viewer in viewers.values {
            guard viewers[viewer.id] === viewer else { continue }
            if let oldest = viewer.pending.first ?? nil, instant - oldest.at >= Self.pendingAge {
                viewer.recover(at: instant)
            }
            if viewer.writingSince.map({ instant - $0 >= Self.progressTimeout }) == true
                || viewer.recoveringSince.map({ instant - $0 >= Self.progressTimeout }) == true {
                viewers[viewer.id] = nil
                viewer.close()
            }
        }
    }

    private func scheduleDeadline() {
        var next: Instant?
        for viewer in viewers.values {
            guard let deadline = viewer.deadline else { continue }
            next = next.map { min($0, deadline) } ?? deadline
        }
        guard next != scheduled else { return }
        timer?.cancel()
        timer = nil
        scheduled = next
        guard let next else { return }
        let delay = next - now()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.scheduled = nil
            self?.expire()
        }
    }
}
