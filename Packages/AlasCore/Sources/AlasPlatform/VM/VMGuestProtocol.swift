import Foundation

/// vsock ports the host and the in-guest helper talk over.
public enum VMGuestPort {
    public static let computerUse: UInt32 = 7041
}

public enum VMGuestLifecycleEvent: String, Codable, Sendable { case stop, resume, turnEnded, sessionEnded }

/// One message on the host/guest vsock stream. Encoded as `{"type":"<case>", …fields}`; `Data` fields
/// are base64 strings.
public enum VMGuestMessage: Codable, Equatable, Sendable {
    // Host to guest.
    case hello(hostVersion: String)
    /// `request` is `ComputerUseCommand.requestJSON()`.
    case command(id: UInt64, sessionID: String, request: Data)
    case cancel(id: UInt64)
    case lifecycle(sessionID: String, event: VMGuestLifecycleEvent)
    case run(id: UInt64, command: String, timeoutSeconds: Int)
    // Guest to host.
    case helloReply(guestVersion: String, accessibility: Bool, screenRecording: Bool)
    /// `body` is an `AlasCLIResponse` encoding.
    case response(id: UInt64, body: Data)
    case runResult(id: UInt64, exitCode: Int32?, stdout: String, stderr: String, truncated: Bool, timedOut: Bool)

    private enum Kind: String, Codable {
        case hello, command, cancel, lifecycle, run, helloReply, response, runResult
    }

    private enum Key: String, CodingKey {
        case type, hostVersion, guestVersion, id, sessionID, request, event, command, timeoutSeconds
        case accessibility, screenRecording, body, exitCode, stdout, stderr, truncated, timedOut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .hello:
            self = .hello(hostVersion: try c.decode(String.self, forKey: .hostVersion))
        case .command:
            self = .command(
                id: try c.decode(UInt64.self, forKey: .id), sessionID: try c.decode(String.self, forKey: .sessionID),
                request: try c.decode(Data.self, forKey: .request)
            )
        case .cancel:
            self = .cancel(id: try c.decode(UInt64.self, forKey: .id))
        case .lifecycle:
            self = .lifecycle(
                sessionID: try c.decode(String.self, forKey: .sessionID),
                event: try c.decode(VMGuestLifecycleEvent.self, forKey: .event)
            )
        case .run:
            self = .run(
                id: try c.decode(UInt64.self, forKey: .id), command: try c.decode(String.self, forKey: .command),
                timeoutSeconds: try c.decode(Int.self, forKey: .timeoutSeconds)
            )
        case .helloReply:
            self = .helloReply(
                guestVersion: try c.decode(String.self, forKey: .guestVersion),
                accessibility: try c.decode(Bool.self, forKey: .accessibility),
                screenRecording: try c.decode(Bool.self, forKey: .screenRecording)
            )
        case .response:
            self = .response(id: try c.decode(UInt64.self, forKey: .id), body: try c.decode(Data.self, forKey: .body))
        case .runResult:
            self = .runResult(
                id: try c.decode(UInt64.self, forKey: .id), exitCode: try c.decodeIfPresent(Int32.self, forKey: .exitCode),
                stdout: try c.decode(String.self, forKey: .stdout), stderr: try c.decode(String.self, forKey: .stderr),
                truncated: try c.decode(Bool.self, forKey: .truncated), timedOut: try c.decode(Bool.self, forKey: .timedOut)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case let .hello(hostVersion):
            try c.encode(Kind.hello, forKey: .type)
            try c.encode(hostVersion, forKey: .hostVersion)
        case let .command(id, sessionID, request):
            try c.encode(Kind.command, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(request, forKey: .request)
        case let .cancel(id):
            try c.encode(Kind.cancel, forKey: .type)
            try c.encode(id, forKey: .id)
        case let .lifecycle(sessionID, event):
            try c.encode(Kind.lifecycle, forKey: .type)
            try c.encode(sessionID, forKey: .sessionID)
            try c.encode(event, forKey: .event)
        case let .run(id, command, timeoutSeconds):
            try c.encode(Kind.run, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(command, forKey: .command)
            try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
        case let .helloReply(guestVersion, accessibility, screenRecording):
            try c.encode(Kind.helloReply, forKey: .type)
            try c.encode(guestVersion, forKey: .guestVersion)
            try c.encode(accessibility, forKey: .accessibility)
            try c.encode(screenRecording, forKey: .screenRecording)
        case let .response(id, body):
            try c.encode(Kind.response, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(body, forKey: .body)
        case let .runResult(id, exitCode, stdout, stderr, truncated, timedOut):
            try c.encode(Kind.runResult, forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(exitCode, forKey: .exitCode)
            try c.encode(stdout, forKey: .stdout)
            try c.encode(stderr, forKey: .stderr)
            try c.encode(truncated, forKey: .truncated)
            try c.encode(timedOut, forKey: .timedOut)
        }
    }
}

/// Length-prefixed framing: a 4-byte big-endian payload length, then the JSON message.
public struct VMGuestFramer: Sendable {
    private var buffer = Data()

    public init() {}

    public static func frame(_ message: VMGuestMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        var length = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + payload
    }

    /// Buffers partial frames and returns every message completed by `bytes`. Throws only when a
    /// complete frame is not a valid message; that frame is dropped, so the stream stays usable.
    public mutating func append(_ bytes: Data) throws -> [VMGuestMessage] {
        buffer.append(bytes)
        var messages: [VMGuestMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { Int($0) << 8 | Int($1) }
            guard buffer.count >= 4 + length else { break }
            let payload = buffer.dropFirst(4).prefix(length)
            buffer = Data(buffer.dropFirst(4 + length))
            messages.append(try JSONDecoder().decode(VMGuestMessage.self, from: Data(payload)))
        }
        return messages
    }
}
