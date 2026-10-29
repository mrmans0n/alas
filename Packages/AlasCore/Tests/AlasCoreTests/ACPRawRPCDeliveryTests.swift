import Foundation
import Synchronization
import Testing
import AlasCore

struct ACPRawRPCDeliveryTests {
    @Test(arguments: ["null", #"{"n":1e999,"big":123456789012345678901234567890,"scaled":1.00e2}"#, "[true,1e999]"])
    func fullSourceRemainsExactWhileResultHasAnExplicitValue(result: String) throws {
        let bytes = Data(" {\"id\":7,\"jsonrpc\":\"2.0\", \"result\":\(result)}\n".utf8)
        let delivery = ACPRawRPCDelivery(frame: bytes, connectionID: UUID(), source: .stdio(requestID: .number(7), method: "session/prompt"))
        let decoded = try delivery.decode()
        #expect(delivery.frame == bytes)
        #expect(decoded.id == .number("7"))
        #expect(try LSPJSONValue.decode(from: #require(decoded.result)) == LSPJSONValue.decode(from: Data(result.utf8)))
        #expect(decoded.error == nil)
    }

    @Test func rawErrorDataIsAuthorityAndHookProjectionDoesNotConsume() throws {
        let bytes = Data(#"{"jsonrpc":"2.0","id":"ns:1","error":{"code":-32044,"message":"changed","data":{"kind":"codex_hook_changed","n":1e999,"big":123456789012345678901234567890}}}"#.utf8)
        let count = Mutex(0)
        let delivery = ACPRawRPCDelivery(frame: bytes, connectionID: UUID(), source: .stdio(requestID: .string("ns:1"), method: "session/prompt"),
            durableConsumptionAcknowledgement: { count.withLock { $0 += 1 } })
        let decoded = try delivery.decode()
        #expect(decoded.result == nil)
        #expect(decoded.error?.code == -32044)
        guard case .object(let fields)? = decoded.rawError, case .object(let data)? = fields["data"] else {
            Issue.record("Missing exact raw error data")
            return
        }
        #expect(data["n"] == .number("1e999"))
        let failure = ACPRawRPCError(delivery: delivery, rpcError: decoded.error)
        #expect(ACPCodexHookReviewError.classify(failure) == .changed)
        #expect(count.withLock { $0 } == 0)
        failure.acknowledgeDurableConsumption()
        #expect(count.withLock { $0 } == 1)
        #expect(failure.delivery.frame == bytes)
    }

    @Test(arguments: [
        (#"-1"#, ACPRawRPCDelivery.Source.stdio(requestID: .number(-1), method: "m")),
        (#""prefix:1""#, .stdio(requestID: .string("prefix:1"), method: "m")),
        ("18446744073709551615", .brokerOperation(operationKey: .init(rawValue: "key"), requestID: .init(rawValue: .max), method: "m")),
    ])
    func supportedRequestDomainsDoNotNarrowEachOther(id: String, source: ACPRawRPCDelivery.Source) throws {
        let bytes = Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":null}".utf8)
        #expect(try ACPRawRPCDelivery(frame: bytes, connectionID: UUID(), source: source).decode().result == Data("null".utf8))
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":8,"result":null}"#,
        #"{"jsonrpc":"2.0","id":7,"method":null,"result":null}"#,
        #"{"jsonrpc":"2.0","id":7,"result":null,"error":{"code":1,"message":"bad"}}"#,
        #"{"jsonrpc":"2.0","id":7,"error":{"code":1e999,"message":"bad"}}"#,
        #"{"jsonrpc":"2.0","id":7,"error":{"code":1,"message":null}}"#,
        #"{"jsonrpc":"1.0","id":7,"result":null}"#,
        #"{"jsonrpc":"2.0","id":7}"#,
        #"{"jsonrpc":"2.0","id":7,"id":7,"result":null}"#,
    ])
    func malformedOrMisboundEvidenceCannotDecodeAsSuccess(json: String) {
        let delivery = ACPRawRPCDelivery(frame: Data(json.utf8), connectionID: UUID(), source: .stdio(requestID: .number(7), method: "m"))
        #expect(throws: (any Error).self) { try delivery.decode() }
    }

    @Test(arguments: ["null", "true", "7.5", "1e999", "18446744073709551616"])
    func unboundParsingStillRejectsUnsupportedIDs(id: String) {
        let delivery = ACPRawRPCDelivery(frame: Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":null}".utf8), connectionID: UUID(), source: .diagnostic)
        #expect(throws: (any Error).self) { try delivery.decode() }
    }

    @Test func responseAndRawErrorViewsShareConsumptionAcrossCopiesConcurrencyAndReentry() async {
        let count = Mutex(0)
        let retained = Mutex<ACPRawRPCDelivery?>(nil)
        let delivery = ACPRawRPCDelivery(frame: Data(), connectionID: UUID(), source: .diagnostic,
            durableConsumptionAcknowledgement: {
                count.withLock { $0 += 1 }
                retained.withLock { $0 }?.acknowledgeDurableConsumption()
            })
        let response = ACPResponse(body: Data("null".utf8), rawDelivery: delivery)
        let error = ACPRawRPCError(delivery: delivery, rpcError: nil)
        retained.withLock { $0 = response.rawDelivery }
        #expect(response.rawDelivery?.receiptID == delivery.receiptID)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { delivery.acknowledgeDurableConsumption() }
                group.addTask { response.durableConsumptionAcknowledgement?() }
                group.addTask { error.acknowledgeDurableConsumption() }
            }
        }
        #expect(count.withLock { $0 } == 1)
        retained.withLock { $0 = nil }
    }
}
