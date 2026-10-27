import Foundation
import Testing
import AlasCore

struct ACPBrokerRawJSONPayloadTests {
    @Test(arguments: try Corpus.load().valid)
    func sharedFixturesPreserveExactSourceBytes(fixture: ValidFixture) throws {
        let expected = try fixture.expectedBytes
        let encoded = try JSONEncoder().encode(fixture.wire)
        let decoded = try JSONDecoder().decode(ACPBrokerRawJSONPayload.self, from: encoded)
        #expect(decoded.bytes == expected)
        let produced = try JSONEncoder().encode(ACPBrokerRawJSONPayload(bytes: expected))
        #expect(try JSONDecoder().decode([String].self, from: produced) == fixture.wire)
    }

    @Test(arguments: try Corpus.load().valid)
    func genericCarriersPreserveEvidenceAcrossHops(fixture: ValidFixture) throws {
        let expected = try fixture.expectedBytes
        let payload = try JSONDecoder().decode(ACPBrokerJSONValue.self,
            from: JSONEncoder().encode(ACPBrokerRawJSONPayload(bytes: expected)))
        var carrier = ACPBrokerJSONValue.object([
            "event": .object(["cursor": .number(7), "rawPayload": payload]),
            "cachedOutcome": .object(["rawPayload": payload]),
        ])
        for _ in 0..<2 {
            carrier = try JSONDecoder().decode(ACPBrokerJSONValue.self, from: JSONEncoder().encode(carrier))
        }
        guard case .object(let fields) = carrier else {
            Issue.record("Expected a carrier object")
            return
        }
        for key in ["event", "cachedOutcome"] {
            guard case .object(let container)? = fields[key] else {
                Issue.record("Missing carrier \(key)")
                continue
            }
            let wire = try #require(container["rawPayload"])
            let recovered = try JSONDecoder().decode(ACPBrokerRawJSONPayload.self, from: JSONEncoder().encode(wire))
            #expect(recovered.bytes == expected)
        }
    }

    @Test(arguments: try Corpus.load().invalid)
    func malformedWrappersAreRejected(fixture: InvalidFixture) throws {
        let data = try JSONEncoder().encode(fixture.wire)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ACPBrokerRawJSONPayload.self, from: data)
        }
    }

    struct ValidFixture: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let wire: [String]
        let sourceUTF8: String?
        let sourceBytes: [UInt8]?
        var testDescription: String { name }

        var expectedBytes: Data {
            get throws {
                try #require((sourceUTF8 == nil) != (sourceBytes == nil))
                if let sourceUTF8 { return Data(sourceUTF8.utf8) }
                return Data(try #require(sourceBytes))
            }
        }
    }

    struct InvalidFixture: Decodable, Sendable, CustomTestStringConvertible {
        let name: String
        let wire: ACPBrokerJSONValue
        var testDescription: String { name }
    }

    private struct Corpus: Decodable {
        let valid: [ValidFixture]
        let invalid: [InvalidFixture]

        static func load() throws -> Self {
            let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/acp-raw-json-payloads.json")
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        }
    }
}
