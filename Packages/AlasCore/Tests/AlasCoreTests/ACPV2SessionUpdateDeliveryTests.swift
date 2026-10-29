import Foundation
import Synchronization
import Testing
import AlasCore

struct ACPV2SessionUpdateDeliveryTests {
    @Test(arguments: [false, true])
    func rawFramesReachTheOwnerWithoutImplicitConsumption(hasCallback: Bool) throws {
        let frame = Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call_update","toolCallId":"t","rawInput":{"n":1e999},"content":[{"type":"terminal","terminalId":"x"}]},"_meta":{"big":123456789012345678901234567890}}}"#.utf8)
        let count = Mutex(0)
        let connectionID = UUID()
        let callback: ACPDurableConsumptionAcknowledgement? = hasCallback ? { @Sendable in count.withLock { $0 += 1 } } : nil
        let delivery = ACPV2SessionUpdateDelivery(frame: frame, connectionID: connectionID,
            durableConsumptionAcknowledgement: callback)
        let event = try delivery.decode()
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: connectionID)
        var owner = ACPV2SessionState(context: context)
        _ = try owner.apply(event, source: .live, context: context)
        #expect(delivery.frame == frame)
        #expect(owner.activity.toolCall(id: "t")?.rawInput == .object(["n": .number("1e999")]))
        #expect(owner.order == [.toolCall("t"), .terminal("x")])
        guard case .object(let fields) = event.rawValue else {
            Issue.record("Expected params object")
            return
        }
        #expect(fields["_meta"] == .object(["big": .number("123456789012345678901234567890")]))
        #expect(count.withLock { $0 } == 0)
        delivery.acknowledgeDurableConsumption()
        #expect(count.withLock { $0 } == (hasCallback ? 1 : 0))
    }

    @Test(arguments: [
        #"{"method":"session/update","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"other","params":{}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","id":null,"params":{}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","id":1e999,"params":{}}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":null}"#,
        #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"state_update","state":null}}}"#,
    ])
    func malformedNotificationsStayRawAndUnconsumed(json: String) {
        let count = Mutex(0)
        let frame = Data(json.utf8)
        let delivery = ACPV2SessionUpdateDelivery(frame: frame, connectionID: UUID(),
            durableConsumptionAcknowledgement: { count.withLock { $0 += 1 } })
        #expect(throws: DecodingError.self) { try delivery.decode() }
        #expect(delivery.frame == frame)
        #expect(count.withLock { $0 } == 0)
    }

    @Test func unknownUpdatesStayUnhandledWithoutConsumption() throws {
        let count = Mutex(0)
        let delivery = ACPV2SessionUpdateDelivery(frame: Data(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"_future","n":1e999}}}"#.utf8), connectionID: UUID(),
            durableConsumptionAcknowledgement: { count.withLock { $0 += 1 } })
        let context = ACPV2MessageTranscript.Context(sessionID: "s", connectionID: delivery.connectionID)
        var owner = ACPV2SessionState(context: context)
        #expect(try owner.apply(delivery.decode(), source: .live, context: context).disposition == .unhandled)
        #expect(count.withLock { $0 } == 0)
        #expect(owner.order.isEmpty)
    }

    @Test func copiedHandlesAcknowledgeOnceAndAllowSynchronousReentry() async {
        let count = Mutex(0)
        let retained = Mutex<ACPV2SessionUpdateDelivery?>(nil)
        let delivery = ACPV2SessionUpdateDelivery(frame: Data(), connectionID: UUID(),
            durableConsumptionAcknowledgement: {
                count.withLock { $0 += 1 }
                retained.withLock { $0 }?.acknowledgeDurableConsumption()
            })
        let copy = delivery
        #expect(copy.receiptID == delivery.receiptID)
        let equalFrame = ACPV2SessionUpdateDelivery(frame: delivery.frame, connectionID: delivery.connectionID)
        #expect(equalFrame.receiptID != delivery.receiptID)
        retained.withLock { $0 = copy }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { delivery.acknowledgeDurableConsumption() } }
        }
        #expect(count.withLock { $0 } == 1)
        retained.withLock { $0 = nil }
    }
}
