import AlasCore
import Foundation
import Testing

struct PeerDeviceProtocolTests {
    private static let deviceID = UUID()
    private static let attachmentID = UUID()

    @Test(arguments: [
        PeerDeviceRequest.list,
        .attach(deviceID: deviceID, attachmentID: attachmentID),
        .detach(attachmentID: attachmentID),
        .takeControl(attachmentID: attachmentID),
        .releaseControl(attachmentID: attachmentID),
        .renewControl(attachmentID: attachmentID, generation: 9),
        .input(attachmentID: attachmentID, leaseGeneration: 9, formatGeneration: 2,
               event: .pointer(phase: .cancel, x: 0.25, y: 0.75)),
        .input(attachmentID: attachmentID, leaseGeneration: 9, formatGeneration: 2,
               event: .key(usage: 4, down: true)),
        .input(attachmentID: attachmentID, leaseGeneration: 9, formatGeneration: 2,
               event: .text("hello")),
        .input(attachmentID: attachmentID, leaseGeneration: 9, formatGeneration: 2,
               event: .scroll(x: 0.5, y: 0.25, dx: -1, dy: 2)),
        .input(attachmentID: attachmentID, leaseGeneration: 9, formatGeneration: 2,
               event: .button(.home)),
    ])
    func deviceRequestsRoundTrip(_ request: PeerDeviceRequest) throws {
        let message = RemoteClientMessage.device(request)
        let json = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(RemoteClientMessage.self, from: json) == message)
    }

    @Test(arguments: [
        PeerDeviceEvent.list([
            .init(id: deviceID, name: "Android", access: .view, availability: .unauthorized, driver: .available),
        ]),
        .attached(attachmentID: attachmentID, ticket: "single-use-ticket"),
        .control(attachmentID: attachmentID, driver: .other(name: "Phone"), generation: 9),
        .refused(attachmentID: attachmentID, reason: "Device offline"),
        .detached(attachmentID: attachmentID, reason: "Grant revoked"),
    ])
    func deviceEventsRoundTrip(_ event: PeerDeviceEvent) throws {
        let message = RemoteServerMessage.device(event)
        let json = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(RemoteServerMessage.self, from: json) == message)
    }

    @Test func inputRequiresBothGenerationFences() throws {
        let missingLease = Data("""
            {"type":"device","device":{"input":{"attachmentID":"\(Self.attachmentID.uuidString)",
            "formatGeneration":2,"event":{"button":{"_0":"home"}}}}}
            """.utf8)
        let missingFormat = Data("""
            {"type":"device","device":{"input":{"attachmentID":"\(Self.attachmentID.uuidString)",
            "leaseGeneration":9,"event":{"button":{"_0":"home"}}}}}
            """.utf8)
        let complete = Data("""
            {"type":"device","device":{"input":{"attachmentID":"\(Self.attachmentID.uuidString)",
            "leaseGeneration":9,"formatGeneration":2,"event":{"button":{"_0":"home"}}}}}
            """.utf8)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(RemoteClientMessage.self, from: complete) == .device(
            .input(attachmentID: Self.attachmentID, leaseGeneration: 9, formatGeneration: 2, event: .button(.home))))
        #expect(throws: DecodingError.self) { try decoder.decode(RemoteClientMessage.self, from: missingLease) }
        #expect(throws: DecodingError.self) { try decoder.decode(RemoteClientMessage.self, from: missingFormat) }
    }

    @Test func attachReplyCarriesTicketRatherThanOrigin() throws {
        let message = RemoteServerMessage.device(.attached(attachmentID: Self.attachmentID, ticket: "ticket"))
        let json = try JSONEncoder().encode(message)
        let envelope = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(envelope["type"] as? String == "device")
        let device = try #require(envelope["device"] as? [String: Any])
        let attached = try #require(device["attached"] as? [String: String])
        #expect(attached == ["attachmentID": Self.attachmentID.uuidString, "ticket": "ticket"])
    }

    @Test func helloAcceptsMissingAndUnknownCapabilities() throws {
        let decoder = JSONDecoder()
        let legacy = Data(#"{"type":"hello","protocolVersion":1,"serverId":"host-A","name":"Mac"}"#.utf8)
        #expect(try decoder.decode(RemoteServerMessage.self, from: legacy) == .hello(
            protocolVersion: 1, serverId: "host-A", name: "Mac"))

        let future = Data(#"{"type":"hello","protocolVersion":1,"serverId":"host-A","name":"Mac","capabilities":["future.v99","peer.device.v1"]}"#.utf8)
        #expect(try decoder.decode(RemoteServerMessage.self, from: future) == .hello(
            protocolVersion: 1, serverId: "host-A", name: "Mac", capabilities: ["future.v99", PeerDeviceCapability.v1]))

        let ack = Data(#"{"type":"helloAck","protocolVersion":1,"capabilities":["future.v99"]}"#.utf8)
        #expect(try decoder.decode(RemoteClientMessage.self, from: ack) == .helloAck(
            protocolVersion: 1, capabilities: ["future.v99"]))
    }

    @Test func unknownDeviceVerbDoesNotDecodeAsAKnownMessage() {
        let json = Data(#"{"type":"device","device":{"futureVerb":{}}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RemoteClientMessage.self, from: json) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RemoteServerMessage.self, from: json) }
    }
}
