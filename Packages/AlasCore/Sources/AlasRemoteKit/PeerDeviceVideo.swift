import Foundation

/// One binary WebSocket message. H.264 payloads are Annex B and PTS is in microseconds.
public enum PeerDeviceVideoPacket: Equatable, Sendable {
    case format(generation: UInt64, width: UInt32, height: UInt32)
    case config(generation: UInt64, bytes: Data)
    case frame(generation: UInt64, pts: UInt64, keyFrame: Bool, bytes: Data)

    // Version, kind, flags, reserved, generation, payload length, dimensions or PTS.
    private static let headerBytes = 24
    public static let maxPacketBytes = 512 * 1024

    public var generation: UInt64 {
        switch self {
        case .format(let generation, _, _), .config(let generation, _), .frame(let generation, _, _, _): generation
        }
    }

    fileprivate var byteCount: Int {
        switch self {
        case .format: Self.headerBytes
        case .config(_, let bytes), .frame(_, _, _, let bytes): Self.headerBytes + bytes.count
        }
    }

    fileprivate var validForWire: Bool {
        guard byteCount <= Self.maxPacketBytes else { return false }
        return switch self {
        case .format(_, let width, let height): Self.validDimensions(width, height)
        case .config(_, let bytes): !bytes.isEmpty
        case .frame(_, let pts, _, let bytes): !bytes.isEmpty && pts <= UInt64(Int64.max)
        }
    }

    public func encoded() -> Data? {
        guard validForWire else { return nil }
        let payload: Data
        let kind: UInt8
        let flags: UInt8
        let metadata: UInt64
        switch self {
        case .format(_, let width, let height):
            kind = 1
            flags = 0
            metadata = (UInt64(width) << 32) | UInt64(height)
            payload = Data()
        case .config(_, let bytes):
            kind = 2
            flags = 0
            metadata = 0
            payload = bytes
        case .frame(_, let pts, let keyFrame, let bytes):
            kind = 3
            flags = keyFrame ? 1 : 0
            metadata = pts
            payload = bytes
        }
        var result = Data(capacity: byteCount)
        result.append(contentsOf: [1, kind, flags, 0])
        Self.append(generation, to: &result)
        Self.append(UInt32(payload.count), to: &result)
        Self.append(metadata, to: &result)
        result.append(payload)
        return result
    }

    public init?(binary: Data) {
        guard (Self.headerBytes...Self.maxPacketBytes).contains(binary.count) else { return nil }
        let start = binary.startIndex
        guard binary[start] == 1, binary[start + 3] == 0 else { return nil }
        let kind = binary[start + 1]
        let flags = binary[start + 2]
        let (generation, length, metadata) = binary.withUnsafeBytes { bytes in
            (
                UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt64.self)),
                UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)),
                UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: 16, as: UInt64.self))
            )
        }
        guard Int(length) == binary.count - Self.headerBytes else { return nil }
        switch kind {
        case 1:
            let width = UInt32(metadata >> 32)
            let height = UInt32(truncatingIfNeeded: metadata)
            guard flags == 0, length == 0, Self.validDimensions(width, height) else { return nil }
            self = .format(generation: generation, width: width, height: height)
        case 2:
            guard flags == 0, length > 0, metadata == 0 else { return nil }
            self = .config(generation: generation, bytes: binary.dropFirst(Self.headerBytes))
        case 3:
            guard flags <= 1, length > 0, metadata <= UInt64(Int64.max) else { return nil }
            self = .frame(generation: generation, pts: metadata, keyFrame: flags == 1, bytes: binary.dropFirst(Self.headerBytes))
        default:
            return nil
        }
    }

    private static func validDimensions(_ width: UInt32, _ height: UInt32) -> Bool {
        (1...8192).contains(width) && (1...8192).contains(height)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Remembers a complete GOP for joining an idle source. Once any frame is lost, the
/// remaining dependent frames cannot be replayed without the next keyframe.
public struct PeerDeviceVideoBootstrap: Sendable {
    public private(set) var format: PeerDeviceVideoPacket?
    private var config: PeerDeviceVideoPacket?
    private var frames: [PeerDeviceVideoPacket] = []
    private var bytes = 0

    public init() {}

    public mutating func update(_ packet: PeerDeviceVideoPacket) {
        switch packet {
        case .format:
            format = packet.validForWire ? packet : nil
            config = nil
            discardFrames()
        case .config:
            guard packet.generation == format?.generation else { return }
            config = packet.validForWire ? packet : nil
            discardFrames()
        case .frame(_, _, let key, _):
            guard packet.generation == format?.generation, let format, let config else { return }
            if key { discardFrames() }
            guard key || !frames.isEmpty else { return }
            guard packet.validForWire, frames.count < 254,
                  packet.byteCount <= PeerDeviceVideoPacket.maxPacketBytes - format.byteCount - config.byteCount - bytes else {
                discardFrames()
                return
            }
            frames.append(packet)
            bytes += packet.byteCount
        }
    }

    /// The current format and config, followed by frames only when the GOP is contiguous.
    public func replay(_ consume: (PeerDeviceVideoPacket) -> Void) {
        guard let format else { return }
        consume(format)
        guard let config else { return }
        consume(config)
        for frame in frames { consume(frame) }
    }

    private mutating func discardFrames() {
        frames.removeAll(keepingCapacity: true)
        bytes = 0
    }
}
