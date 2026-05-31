import Foundation
import Testing
@testable import Alas

@Suite("ACPContentBlock image")
struct ACPContentBlockImageTests {
    @Test("encodes inline base64 image with data and mimeType")
    func encodesInlineImage() throws {
        let block = ACPContentBlock.image(data: "QUJD", uri: nil, mimeType: "image/png")
        let data = try JSONEncoder().encode(block)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "image")
        #expect(json["data"] as? String == "QUJD")
        #expect(json["mimeType"] as? String == "image/png")
        #expect(json["uri"] == nil)
    }

    @Test("round-trips an image block carrying only a uri")
    func roundTripsUriOnly() throws {
        let block = ACPContentBlock.image(data: nil, uri: "file:///tmp/a.png", mimeType: "image/png")
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(ACPContentBlock.self, from: data)
        #expect(decoded == block)
    }

    @Test("round-trips an image block carrying only base64 data")
    func roundTripsDataOnly() throws {
        let block = ACPContentBlock.image(data: "QUJD", uri: nil, mimeType: "image/png")
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(ACPContentBlock.self, from: data)
        #expect(decoded == block)
    }
}
