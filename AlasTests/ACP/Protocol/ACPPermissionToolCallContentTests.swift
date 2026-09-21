import Foundation
import Testing
@testable import Alas

@Suite("ACPPermissionToolCall content decoding")
struct ACPPermissionToolCallContentTests {
    @Test("a diff block followed by a trailing text block decodes without losing the text")
    func diffThenTextDecodesCorrectly() throws {
        let json = """
        {
          "toolCallId": "call_1",
          "content": [
            {"type": "diff", "path": "/tmp/f.txt", "oldText": "a", "newText": "b"},
            {"type": "content", "content": {"type": "text", "text": "Explanation of the edit."}}
          ]
        }
        """.data(using: .utf8)!
        let toolCall = try JSONDecoder().decode(ACPPermissionToolCall.self, from: json)
        let blocks = try #require(toolCall.content)
        #expect(blocks.count == 2)
        guard case .diff(let path, _, let newText) = blocks[0] else {
            Issue.record("expected first block to decode as .diff")
            return
        }
        #expect(path == "/tmp/f.txt")
        #expect(newText == "b")
        guard case .content(.text(let text)) = blocks[1] else {
            Issue.record("expected second block to decode as .content(.text)")
            return
        }
        #expect(text == "Explanation of the edit.")
    }

    @Test("a bare content block (no tagged-union wrapper) still decodes as text")
    func bareContentBlockDecodesAsText() throws {
        // Real permission-request payloads (see
        // AlasTests/ACP/Fixtures/permission-request.json) send content
        // blocks unwrapped — `{"type":"text",...}` — rather than the ACP
        // spec's `{"type":"content","content":{"type":"text",...}}` union.
        // Both shapes must decode to the same case.
        let json = """
        {
          "toolCallId": "call_1",
          "content": [
            {"type": "text", "text": "swift build"}
          ]
        }
        """.data(using: .utf8)!
        let toolCall = try JSONDecoder().decode(ACPPermissionToolCall.self, from: json)
        let blocks = try #require(toolCall.content)
        #expect(blocks.count == 1)
        guard case .content(.text(let text)) = blocks[0] else {
            Issue.record("expected the bare block to decode as .content(.text)")
            return
        }
        #expect(text == "swift build")
    }
}
