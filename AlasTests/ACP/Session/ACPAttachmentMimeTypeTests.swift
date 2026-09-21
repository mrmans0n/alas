import Foundation
import Testing
@testable import Alas

@Suite("ACPMessage.Attachment mimeType")
struct ACPAttachmentMimeTypeTests {
    @Test("decodes legacy attachment JSON without mimeType as nil")
    func decodesLegacy() throws {
        let json = #"{"uri":"file:///a.swift","name":"a.swift"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ACPMessage.Attachment.self, from: json)
        #expect(decoded.mimeType == nil)
        #expect(decoded.uri == "file:///a.swift")
    }

    @Test("round-trips an image attachment with mimeType")
    func roundTripsImage() throws {
        let att = ACPMessage.Attachment(uri: "file:///tmp/x.png", name: "x.png", mimeType: "image/png")
        let data = try JSONEncoder().encode(att)
        let decoded = try JSONDecoder().decode(ACPMessage.Attachment.self, from: data)
        #expect(decoded == att)
        #expect(decoded.mimeType == "image/png")
    }

    @Test("decodes legacy attachment JSON without textOffset as nil")
    func decodesLegacyWithoutTextOffset() throws {
        let json = #"{"uri":"file:///tmp/x.png","name":"x.png","mimeType":"image/png"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ACPMessage.Attachment.self, from: json)
        #expect(decoded.textOffset == nil)
    }

    @Test("round-trips an image attachment with textOffset")
    func roundTripsTextOffset() throws {
        let att = ACPMessage.Attachment(uri: "file:///tmp/x.png", name: "x.png", mimeType: "image/png", textOffset: 7)
        let data = try JSONEncoder().encode(att)
        let decoded = try JSONDecoder().decode(ACPMessage.Attachment.self, from: data)
        #expect(decoded.textOffset == 7)
    }

    @Test("equality ignores textOffset")
    func equalityIgnoresTextOffset() {
        let a = ACPMessage.Attachment(uri: "file:///tmp/x.png", name: "x.png", mimeType: "image/png", textOffset: 3)
        let b = ACPMessage.Attachment(uri: "file:///tmp/x.png", name: "x.png", mimeType: "image/png", textOffset: nil)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }
}
