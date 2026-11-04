import Foundation
import Synchronization
import Testing
import AlasCore

struct ACPV2InboundDeliveryTests {
    @MainActor @Test func selectedOrderedIntakeKeepsMethodOrderAndOriginalReceipts() async throws {
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: .v2)
        let intake = try client.claimV2OrderedIntake()
        #expect(throws: (any Error).self) { try client.claimV2OrderedIntake() }
        try client.start()
        defer { transport.terminate() }
        let count = Mutex(0)
        let frames = [
            #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"upstream","update":{"sessionUpdate":"state_update","state":"running"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"peer/request"}"#,
            "malformed",
            #"{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":7}}"#,
        ]
        for frame in frames { transport.emit(frame, onConsumed: { count.withLock { $0 += 1 } }) }
        // RPC responses bypass the undrained method FIFO.
        _ = try await client.send(.init(method: "initialize", params: ACPV2InitializeParams(info: .init(name: "alas", version: "test"))))
        var iterator = intake.events.makeAsyncIterator()
        for index in frames.indices {
            let event = try #require(await iterator.next())
            switch event {
            case .update(let delivery):
                #expect(index == 0 && delivery.frame == Data(frames[index].utf8))
                delivery.acknowledgeDurableConsumption()
                delivery.acknowledgeDurableConsumption()
            case .inbound(let delivery):
                #expect((index == 1 || index == 3) && delivery.frame == Data(frames[index].utf8))
                if index == 1 { #expect(client.canRespondToV2Request( delivery)) }
                delivery.acknowledgeDurableConsumption()
                delivery.acknowledgeDurableConsumption()
            case .diagnostic(let delivery):
                #expect(index == 2 && delivery.frame == Data(frames[index].utf8))
                delivery.acknowledgeDurableConsumption()
                delivery.acknowledgeDurableConsumption()
            }
        }
        #expect(count.withLock { $0 } == 4)
        var split = client.incomingV2Inbound.makeAsyncIterator()
        #expect(await split.next() == nil)
        transport.terminate()
        #expect(await iterator.next() == nil)
    }

    @MainActor @Test(arguments: ["started", "v1", "stopped", "bootstrap"])
    func orderedClaimRequiresAnUnusedClient(reason: String) async throws {
        let transport = BootstrapTransport()
        let client = ACPStdioClient(transport: transport, sessionUpdateProtocolVersion: reason == "v1" ? .v1 : .v2)
        defer { transport.terminate() }
        if reason == "started" { try client.start() }
        if reason == "stopped" { await client.shutdown() }
        if reason == "bootstrap" { _ = try client.claimV2Bootstrap() }
        #expect(throws: (any Error).self) { try client.claimV2OrderedIntake() }
        #expect(transport.frames.withLock { $0 }.isEmpty)
    }

    @Test(arguments: ["", #","id":-7"#, #","id":"prefix:7""#])
    func opaqueMethodParamsRemainExactWithoutConsumption(id: String) throws {
        let bytes = Data(" \n{\"jsonrpc\":\"2.0\",\"method\":\"peer/future\"\(id),\"params\":{\"n\":1e999,\"big\":123456789012345678901234567890}}\n".utf8)
        let count = Mutex(0)
        let delivery = ACPV2InboundDelivery(frame: bytes, connectionID: UUID(), source: .stdio,
            durableConsumptionAcknowledgement: { count.withLock { $0 += 1 } })
        let header = try delivery.decodeHeader()
        #expect(header.method == "peer/future")
        #expect(header.id == (id.isEmpty ? nil : (id.contains("prefix") ? .string("prefix:7") : .number(-7))))
        #expect(delivery.frame == bytes)
        #expect(delivery.source == .stdio)
        guard case .object(let params)? = header.params else { Issue.record("Missing opaque params")
        return }
        #expect(params["n"] == .number("1e999"))
        #expect(params["big"] == .number("123456789012345678901234567890"))
        #expect(count.withLock { $0 } == 0)
    }

    @Test(arguments: ["", #","params":null"#, #","params":[1e999]"#, #","params":true"#])
    func headerValidityDoesNotGrantKnownPayloadValidity(params: String) throws {
        let bytes = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"session/request_permission\"\(params)}".utf8)
        let header = try ACPV2InboundDelivery(frame: bytes, connectionID: UUID(), source: .stdio).decodeHeader()
        #expect(header.id == .number(1))
        if params.isEmpty { #expect(header.params == nil) }
        else if params.contains("null") { #expect(header.params == .null) }
        else if params.contains("true") { #expect(header.params == .bool(true)) }
        else { #expect(header.params == .array([.number("1e999")])) }
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":null,"method":"m"}"#,
        #"{"jsonrpc":"2.0","id":true,"method":"m"}"#,
        #"{"jsonrpc":"2.0","id":7.5,"method":"m"}"#,
        #"{"jsonrpc":"2.0","id":18446744073709551615,"method":"m"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"m","result":null}"#,
        #"{"jsonrpc":"2.0","id":1,"method":"m","error":null}"#,
        #"{"jsonrpc":"1.0","id":1,"method":"m"}"#,
        #"{"jsonrpc":"2.0","id":1,"method":null}"#,
        #"{"jsonrpc":"2.0","id":1,"id":2,"method":"m"}"#,
        #"{"jsonrpc":"2.0","id":1,"result":null}"#,
    ])
    func invalidOrAmbiguousHeaderCannotAcquireRequestIdentity(json: String) {
        let delivery = ACPV2InboundDelivery(frame: Data(json.utf8), connectionID: UUID(), source: .stdio)
        #expect(throws: (any Error).self) { try delivery.decodeHeader() }
    }

    @Test func copiedReceiptsConsumeOnceAcrossConcurrencyAndReentry() async throws {
        let count = Mutex(0)
        let retained = Mutex<ACPV2InboundDelivery?>(nil)
        let frame = Data(#"{"jsonrpc":"2.0","method":"notice"}"#.utf8)
        let original = ACPV2InboundDelivery(frame: frame, connectionID: UUID(), source: .stdio,
            durableConsumptionAcknowledgement: {
                count.withLock { $0 += 1 }
                retained.withLock { $0 }?.acknowledgeDurableConsumption()
            })
        let copy = original
        #expect(copy.receiptID == original.receiptID)
        #expect(ACPV2InboundDelivery(frame: frame, connectionID: original.connectionID, source: .stdio).receiptID != original.receiptID)
        retained.withLock { $0 = copy }
        _ = try copy.decodeHeader()
        #expect(count.withLock { $0 } == 0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { copy.acknowledgeDurableConsumption() }
                group.addTask { original.acknowledgeDurableConsumption() }
            }
        }
        #expect(count.withLock { $0 } == 1)
        retained.withLock { $0 = nil }
        #expect(throws: (any Error).self) {
            try ACPV2InboundDelivery(frame: Data([255, 0]), connectionID: UUID(), source: .stdio).decodeHeader()
        }
    }
}
