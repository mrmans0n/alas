import Foundation
import Testing
@testable import Alas

@Suite("ACPToolCallContent decoding")
struct ACPToolCallContentTests {
    @Test("decodes wrapped content blocks (text, resource_link, image)")
    func contentVariants() throws {
        let items = try decode("tool-call-content-blocks")
        #expect(items.count == 3)
        guard case .content(.text(let s)) = items[0] else {
            Issue.record("expected .content(.text)")
            return
        }
        #expect(s == "hello")
        guard case .content(.resourceLink(let uri, let name)) = items[1] else {
            Issue.record("expected .content(.resourceLink)")
            return
        }
        #expect(uri == "file:///tmp/x.txt")
        #expect(name == "x.txt")
        guard case .content(.image(let uri2, let mime)) = items[2] else {
            Issue.record("expected .content(.image)")
            return
        }
        #expect(uri2 == "file:///tmp/y.png")
        #expect(mime == "image/png")
    }

    @Test("decodes diff variant with and without oldText")
    func diffVariant() throws {
        let items = try decode("tool-call-content-diff")
        #expect(items.count == 2)
        guard case .diff(let path, let old, let new) = items[0] else {
            Issue.record("expected .diff")
            return
        }
        #expect(path == "src/foo.swift")
        #expect(old == "let a = 1\n")
        #expect(new == "let a = 2\n")
        guard case .diff(_, let old2, _) = items[1] else {
            Issue.record("expected .diff")
            return
        }
        #expect(old2 == nil)
    }

    @Test("decodes terminal variant")
    func terminalVariant() throws {
        let items = try decode("tool-call-content-terminal")
        #expect(items.count == 1)
        guard case .terminal(let id) = items[0] else {
            Issue.record("expected .terminal")
            return
        }
        #expect(id == "term-42")
    }

    @Test("unknown type decodes to .unknown rather than failing")
    func unknownVariant() throws {
        let data = Data(#"[{"type":"future_thing","payload":{}}]"#.utf8)
        let items = try JSONDecoder().decode([ACPToolCallContent].self, from: data)
        #expect(items.count == 1)
        if case .unknown = items[0] {} else { Issue.record("expected .unknown") }
    }

    private func decode(_ name: String) throws -> [ACPToolCallContent] {
        let bundle = Bundle(for: ACPToolCallContentFixtureMarker.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode([ACPToolCallContent].self,
                                        from: try Data(contentsOf: url))
    }
}

private final class ACPToolCallContentFixtureMarker {}
