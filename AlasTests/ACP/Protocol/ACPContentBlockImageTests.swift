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

    @Test("round-trips embedded text resource block")
    func roundTripsResource() throws {
        let block = ACPContentBlock.resource(
            uri: "file:///tmp/File.swift",
            mimeType: "text/plain",
            text: "let value = 1\n"
        )
        let data = try JSONEncoder().encode(block)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "resource")
        let resource = try #require(json["resource"] as? [String: Any])
        #expect(resource["uri"] as? String == "file:///tmp/File.swift")
        #expect(resource["mimeType"] as? String == "text/plain")
        #expect(resource["text"] as? String == "let value = 1\n")

        let decoded = try JSONDecoder().decode(ACPContentBlock.self, from: data)
        #expect(decoded == block)
    }

    @Test("round-trips an embedded blob resource as a resource with blob and no text")
    func roundTripsBlobResource() throws {
        let block = ACPContentBlock.blobResource(uri: "file:///tmp/a.pdf", mimeType: "application/pdf", blob: "QUJD")
        let data = try JSONEncoder().encode(block)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let resource = try #require(json["resource"] as? [String: Any])
        #expect(json["type"] as? String == "resource")
        #expect(resource["uri"] as? String == "file:///tmp/a.pdf")
        #expect(resource["mimeType"] as? String == "application/pdf")
        #expect(resource["blob"] as? String == "QUJD")
        #expect(resource["text"] == nil)
        #expect(try JSONDecoder().decode(ACPContentBlock.self, from: data) == block)
    }

    @Test("a resource keeps its text shape, and one with neither field stays a link", arguments: [
        (#"{"uri":"file:///a/b.txt","text":"hi"}"#, ACPContentBlock.resource(uri: "file:///a/b.txt", mimeType: nil, text: "hi")),
        (#"{"uri":"file:///a/b.txt","text":"hi","blob":"QUJD"}"#, ACPContentBlock.resource(uri: "file:///a/b.txt", mimeType: nil, text: "hi")),
        (#"{"uri":"file:///a/b.txt"}"#, ACPContentBlock.resourceLink(uri: "file:///a/b.txt", name: "b.txt")),
    ])
    func decodesExistingResourceShapes(resource: String, expected: ACPContentBlock) throws {
        let json = Data(#"{"type":"resource","resource":\#(resource)}"#.utf8)
        #expect(try JSONDecoder().decode(ACPContentBlock.self, from: json) == expected)
    }
}
