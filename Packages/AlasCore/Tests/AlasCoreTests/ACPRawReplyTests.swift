import Foundation
import Testing
import AlasCore

struct ACPRawReplyTests {
    @Test(arguments: ["null", #"{"n":1e999,"big":123456789012345678901234567890}"#, #"{"text":"line\nnext"}"#])
    func validationAndWireRoundTripPreserveEveryResponseByte(result: String) throws {
        let bytes = Data(" {\"jsonrpc\":\"2.0\",\"id\":-7,\"result\":\(result)} ".utf8)
        #expect(try ACPRawReply.validateFrame(bytes) == .number(-7))
        let params = ACPBrokerRespondExactParams(brokerId: .init(rawValue: "b"), generation: .init(rawValue: 1),
            pendingRequestId: "\u{feff}é\0", originCursor: .init(rawValue: 3), operationKey: .init(rawValue: "reply"), frame: .init(bytes: bytes))
        let copy = try JSONDecoder().decode(ACPBrokerRespondExactParams.self, from: JSONEncoder().encode(params))
        #expect(copy.frame.bytes == bytes)
        #expect(Data(copy.pendingRequestId.utf8) == Data(params.pendingRequestId.utf8))
        #expect(copy.wireContext == .rawV2)
        let proof = ACPBrokerRawReplyResult(params: params, status: .written)
        #expect(proof.matches(params))
        let wrong = ACPBrokerRespondExactParams(brokerId: params.brokerId, generation: params.generation,
            pendingRequestId: "\u{feff}e\u{301}\0", originCursor: params.originCursor, operationKey: params.operationKey, frame: params.frame)
        #expect(!proof.matches(wrong))
    }

    @Test(arguments: try replyCorpus())
    func sharedEnvelopeCasesAgreeBeforeHandoff(fixture: ReplyFixture) throws {
        let frame = Data(fixture.frame.utf8)
        if fixture.valid { _ = try ACPRawReply.validateFrame(frame) }
        else { #expect(throws: ACPBrokerRawReplyError.rejected(.invalid)) { try ACPRawReply.validateFrame(frame) } }
    }
}

struct ReplyFixture: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let frame: String
    let valid: Bool
    var testDescription: String { name }
}

private func replyCorpus() throws -> [ReplyFixture] {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/acp-raw-replies.json")
    return try JSONDecoder().decode([ReplyFixture].self, from: Data(contentsOf: path))
}
