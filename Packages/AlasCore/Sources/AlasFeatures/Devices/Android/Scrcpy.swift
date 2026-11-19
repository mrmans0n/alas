import Foundation

public enum ScrcpyError: Error, Equatable, Sendable {
    case unsupportedCodec(UInt32)
    case invalidVideoPayloadSize(Int)
    case unknownDeviceMessage(UInt8)
}

public enum ScrcpyVideoEvent: Equatable, Sendable {
    /// A new capture session: the video's size changed (a rotation).
    case session(width: Int, height: Int)
    /// The codec configuration: H.264's SPS and PPS, Annex B.
    case config(Data)
    case frame(Data, pts: UInt64, keyFrame: Bool)
}

/// scrcpy's video socket after the dummy byte and device name: a codec id,
/// then 12-byte session or frame headers, each frame followed by its payload.
public struct ScrcpyVideoParser: Sendable {
    private var buffer = Data()
    private var codecRead = false

    public init() {}

    public mutating func feed(_ data: Data) throws -> [ScrcpyVideoEvent] {
        buffer += data
        var events: [ScrcpyVideoEvent] = []
        if !codecRead {
            guard buffer.count >= 4 else { return [] }
            let codec = Self.u32(buffer, 0)
            guard codec == 0x6832_3634 else { throw ScrcpyError.unsupportedCodec(codec) } // "h264"
            buffer.removeFirst(4)
            codecRead = true
        }
        while buffer.count >= 12 {
            let first = buffer[buffer.startIndex]
            if first & 0x80 != 0 {
                events.append(.session(width: Int(Self.u32(buffer, 4)), height: Int(Self.u32(buffer, 8))))
                buffer.removeFirst(12)
                continue
            }
            let size = Int(Self.u32(buffer, 8))
            guard 1...8 * 1024 * 1024 ~= size else { throw ScrcpyError.invalidVideoPayloadSize(size) }
            guard buffer.count >= 12 + size else { break }
            let flags = Self.u64(buffer, 0)
            let payload = buffer.subdata(in: buffer.startIndex + 12..<buffer.startIndex + 12 + size)
            buffer.removeFirst(12 + size)
            if flags & (1 << 62) != 0 {
                events.append(.config(payload))
            } else {
                events.append(.frame(payload, pts: flags & ((1 << 61) - 1), keyFrame: flags & (1 << 61) != 0))
            }
        }
        return events
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.dropFirst(offset).prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func u64(_ data: Data, _ offset: Int) -> UInt64 {
        data.dropFirst(offset).prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }
}

/// Messages to scrcpy's control socket.
public enum ScrcpyControl {
    public enum KeyAction: UInt8, Sendable { case down = 0, up = 1 }
    public enum TouchAction: UInt8, Sendable { case down = 0, up = 1, move = 2, cancel = 3 }

    /// scrcpy's pointer id for a finger that isn't the mouse: touches act like the touchscreen.
    public static let fingerPointerID: UInt64 = .max - 1

    public static func keycode(_ action: KeyAction, keycode: Int32, repeat count: Int32 = 0, metastate: Int32 = 0) -> Data {
        var data = Data([0, action.rawValue])
        data.append(be: UInt32(bitPattern: keycode))
        data.append(be: UInt32(bitPattern: count))
        data.append(be: UInt32(bitPattern: metastate))
        return data
    }

    /// Text the device types through its key map; characters it can't type are dropped.
    public static func injectText(_ text: String) -> Data {
        let utf8 = Data(text.utf8)
        var data = Data([1])
        data.append(be: UInt32(utf8.count))
        return data + utf8
    }

    /// `x` and `y` are in the video's pixels; `width` and `height` must be the
    /// current session's size, or the server drops the event.
    public static func touch(
        _ action: TouchAction, x: Int32, y: Int32, width: UInt16, height: UInt16,
        pointerID: UInt64 = fingerPointerID, pressure: Double, actionButton: UInt32 = 0, buttons: UInt32 = 0
    ) -> Data {
        var data = Data([2, action.rawValue])
        data.append(be: pointerID)
        appendPosition(&data, x: x, y: y, width: width, height: height)
        data.append(be: pressure >= 1 ? UInt16.max : UInt16(max(0, pressure) * 65536))
        data.append(be: actionButton)
        data.append(be: buttons)
        return data
    }

    /// scrcpy forwards CANCEL to Android, but requires UP to retire the finger.
    public static func cancelTouch(x: Int32, y: Int32, width: UInt16, height: UInt16) -> Data {
        touch(.cancel, x: x, y: y, width: width, height: height, pressure: 0)
            + touch(.up, x: x, y: y, width: width, height: height, pressure: 0)
    }

    /// `horizontal` and `vertical` are scroll steps, clamped to ±16.
    public static func scroll(
        x: Int32, y: Int32, width: UInt16, height: UInt16, horizontal: Double, vertical: Double, buttons: UInt32 = 0
    ) -> Data {
        var data = Data([3])
        appendPosition(&data, x: x, y: y, width: width, height: height)
        data.append(be: UInt16(bitPattern: fixedPoint(horizontal / 16)))
        data.append(be: UInt16(bitPattern: fixedPoint(vertical / 16)))
        data.append(be: buttons)
        return data
    }

    public static func backOrScreenOn(_ action: KeyAction) -> Data {
        Data([4, action.rawValue])
    }

    /// `copy` true asks the device to copy the selection first.
    public static func getClipboard(copy: Bool) -> Data {
        Data([8, copy ? 1 : 0])
    }

    /// The most clipboard text scrcpy v5.0.1 accepts, in UTF-8 bytes.
    public static let clipboardTextLimit = 262_130

    /// Text past `clipboardTextLimit` is cut at a character boundary.
    public static func setClipboard(sequence: UInt64, text: String, paste: Bool) -> Data {
        var utf8 = Data(text.utf8)
        if utf8.count > clipboardTextLimit {
            var end = clipboardTextLimit
            // Back off continuation bytes (10xxxxxx) to the start of a character.
            while end > 0, utf8[end] & 0xC0 == 0x80 { end -= 1 }
            utf8 = utf8.prefix(end)
        }
        var data = Data([9])
        data.append(be: sequence)
        data.append(paste ? 1 : 0)
        data.append(be: UInt32(utf8.count))
        return data + utf8
    }

    private static func appendPosition(_ data: inout Data, x: Int32, y: Int32, width: UInt16, height: UInt16) {
        data.append(be: UInt32(bitPattern: x))
        data.append(be: UInt32(bitPattern: y))
        data.append(be: width)
        data.append(be: height)
    }

    /// scrcpy's float to i16 fixed point over [-1, 1].
    private static func fixedPoint(_ value: Double) -> Int16 {
        let clamped = min(max(value, -1), 1)
        return clamped >= 1 ? .max : Int16(clamped * 32768)
    }
}

public enum ScrcpyDeviceMessage: Equatable, Sendable {
    case clipboard(String)
    case ackClipboard(UInt64)
    case uhidOutput(id: UInt16, data: Data)
}

/// The control socket's messages from the device.
public struct ScrcpyDeviceMessageParser: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func feed(_ data: Data) throws -> [ScrcpyDeviceMessage] {
        buffer += data
        var messages: [ScrcpyDeviceMessage] = []
        while let type = buffer.first {
            switch type {
            case 0:
                guard buffer.count >= 5 else { return messages }
                let length = Int(ScrcpyVideoParser.u32(buffer, 1))
                guard buffer.count >= 5 + length else { return messages }
                let text = buffer.subdata(in: buffer.startIndex + 5..<buffer.startIndex + 5 + length)
                messages.append(.clipboard(String(decoding: text, as: UTF8.self)))
                buffer.removeFirst(5 + length)
            case 1:
                guard buffer.count >= 9 else { return messages }
                messages.append(.ackClipboard(ScrcpyVideoParser.u64(buffer, 1)))
                buffer.removeFirst(9)
            case 2:
                guard buffer.count >= 5 else { return messages }
                let id = UInt16(ScrcpyVideoParser.u32(buffer, 1) >> 16)
                let size = Int(ScrcpyVideoParser.u32(buffer, 1) & 0xFFFF)
                guard buffer.count >= 5 + size else { return messages }
                messages.append(.uhidOutput(id: id, data: buffer.subdata(in: buffer.startIndex + 5..<buffer.startIndex + 5 + size)))
                buffer.removeFirst(5 + size)
            default:
                throw ScrcpyError.unknownDeviceMessage(type)
            }
        }
        return messages
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(be value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
