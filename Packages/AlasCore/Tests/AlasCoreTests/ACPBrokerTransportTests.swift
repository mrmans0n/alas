import Foundation
import Testing
import AlasCore

struct ACPBrokerTransportTests {
    @Test(arguments: [
        (#"{"acpVersion":1,"payloadFormat":"structured"}"#, true),
        (#"{"acpVersion":2,"payloadFormat":"alas.acp.raw-json.v1"}"#, true),
        (#"{"acpVersion":1,"payloadFormat":"alas.acp.raw-json.v1"}"#, false),
        (#"{"acpVersion":2,"payloadFormat":"structured"}"#, false),
        (#"{"acpVersion":3,"payloadFormat":"alas.acp.raw-json.v1"}"#, false),
        (#"{"acpVersion":2}"#, false),
        (#"{"acpVersion":true,"payloadFormat":"alas.acp.raw-json.v1"}"#, false),
    ])
    func onlyExplicitWireContextsAreAccepted(json: String, accepted: Bool) throws {
        if accepted {
            let context = try JSONDecoder().decode(ACPBrokerWireContext.self, from: Data(json.utf8))
            #expect(try JSONDecoder().decode(ACPBrokerWireContext.self, from: JSONEncoder().encode(context)) == context)
        } else {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(ACPBrokerWireContext.self, from: Data(json.utf8))
            }
        }
    }

    @Test(arguments: ["null", #"{"n":1e999,"big":123456789012345678901234567890,"scaled":1.00e2}"#])
    func rawResultsStayExactAndNullIsPresent(result: String) throws {
        let frame = ACPBrokerRawJSONPayload(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\(result)}".utf8))
        let response = try ACPBrokerRawResponse.decode(frame, expectedID: 7)
        let body = try #require(response.result)
        #expect(try LSPJSONValue.decode(from: body) == LSPJSONValue.decode(from: Data(result.utf8)))
        #expect(response.error == nil)
    }

    @Test func rawErrorProjectionKeepsOpaqueEvidenceAndRejectsContradictions() throws {
        let bytes = Data(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32044,"message":"Review changed","data":{"kind":"codex_hook_changed","n":1e999}}}"#.utf8)
        let frame = ACPBrokerRawJSONPayload(bytes: bytes)
        let response = try ACPBrokerRawResponse.decode(frame, expectedID: 7)
        let error = try #require(response.error)
        #expect(error.code == -32044)
        #expect(error.message == "Review changed")
        #expect(ACPCodexHookReviewError.classify(error) != nil)
        #expect(frame.bytes == bytes)
        #expect(throws: (any Error).self) {
            try ACPBrokerRawResponse.decode(frame, expectedID: 7,
                projectedError: JSONRPCError(code: -32603, message: "different", data: nil))
        }
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","id":8,"result":null}"#,
        #"{"jsonrpc":"2.0","id":7}"#,
        #"{"jsonrpc":"2.0","id":7,"result":null,"error":{"code":1,"message":"bad"}}"#,
        #"{"jsonrpc":"2.0","id":7,"error":{"code":1e999,"message":"bad"}}"#,
    ])
    func malformedOrMisboundResponsesNeverBecomeSuccess(json: String) {
        #expect(throws: (any Error).self) {
            try ACPBrokerRawResponse.decode(ACPBrokerRawJSONPayload(bytes: Data(json.utf8)), expectedID: 7)
        }
    }
}
