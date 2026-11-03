import Foundation
import Synchronization
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
        guard case .content(.image(_, let uri2, let mime)) = items[2] else {
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
        guard case .diff(let path, let old, let new, _, _, _) = items[0] else {
            Issue.record("expected .diff")
            return
        }
        #expect(path == "src/foo.swift")
        #expect(old == "let a = 1\n")
        #expect(new == "let a = 2\n")
        guard case .diff(_, let old2, _, _, _, _) = items[1] else {
            Issue.record("expected .diff")
            return
        }
        #expect(old2 == nil)
    }

    @Test("decodes AIR diffStats and kind on a diff block, falling back to nil when absent")
    func diffStatsVariant() throws {
        let items = try decode("tool-call-content-diff-stats")
        #expect(items.count == 3)

        guard case .diff(let path, _, _, let kind, let stats, _) = items[0] else {
            Issue.record("expected .diff")
            return
        }
        #expect(path == "src/foo.swift")
        #expect(kind == "update")
        #expect(stats == ACPDiffStats(added: 12, removed: 3))

        guard case .diff(_, _, _, let kind2, let stats2, _) = items[1] else {
            Issue.record("expected .diff")
            return
        }
        #expect(kind2 == "add")
        #expect(stats2 == nil)

        guard case .diff(_, _, _, let kind3, let stats3, _) = items[2] else {
            Issue.record("expected .diff")
            return
        }
        #expect(kind3 == nil)
        #expect(stats3 == nil)
    }

    @Test("decodes the diffPatch payload on Claude and Codex diff blocks and drops a malformed one")
    func diffPatchVariant() throws {
        let text = "diff --git a/repo/a.txt b/repo/a.txt\n--- a/repo/a.txt\n+++ b/repo/a.txt\n@@ -1 +1 @@\n-a\n+b\n"
        let patch = #"{"version":1,"format":"git_patch","text":"\#(text.replacingOccurrences(of: "\n", with: "\\n"))"}"#
        let json = """
        [
          {"type":"diff","path":"/repo/a.txt","oldText":null,"newText":"","_meta":{"diffPatch":\(patch)}},
          {"type":"diff","path":"/repo/a.txt","oldText":null,"newText":"","_meta":{"kind":"update","diffPatch":\(patch)}},
          {"type":"diff","path":"/repo/b.txt","newText":"b","_meta":{"diffPatch":"x","kind":"add"}},
          {"type":"diff","path":"/repo/a.txt","newText":"","_meta":{"jetbrains":{"air":{"diffStats":"x"}},"kind":"update","diffPatch":\(patch)}}
        ]
        """
        let items = try JSONDecoder().decode([ACPToolCallContent].self, from: Data(json.utf8))
        #expect(items.count == 4)
        let expected = ACPDiffPatchPayload(version: 1, format: "git_patch", text: text)

        guard case .diff(_, let old, let new, let kind, _, let claudePatch) = items[0] else {
            Issue.record("expected .diff")
            return
        }
        #expect(claudePatch == expected)
        #expect(old == nil)
        #expect(new == "")
        #expect(kind == nil)

        guard case .diff(_, _, _, let codexKind, _, let codexPatch) = items[1] else {
            Issue.record("expected .diff")
            return
        }
        #expect(codexKind == "update")
        #expect(codexPatch == expected)

        guard case .diff(_, _, _, let badKind, _, let badPatch) = items[2] else {
            Issue.record("expected .diff")
            return
        }
        #expect(badPatch == nil)
        #expect(badKind == "add")

        // Malformed AIR stats must not drop the patch or the kind.
        guard case .diff(_, _, _, let airKind, let airStats, let airPatch) = items[3] else {
            Issue.record("expected .diff")
            return
        }
        #expect(airKind == "update")
        #expect(airStats == nil)
        #expect(airPatch == expected)

        let encoded = try JSONEncoder().encode(items)
        #expect(try JSONDecoder().decode([ACPToolCallContent].self, from: encoded) == items)
        let reencoded = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let meta = try #require(reencoded[0]["_meta"] as? [String: Any])
        let diffPatch = try #require(meta["diffPatch"] as? [String: Any])
        #expect(diffPatch["text"] as? String == text)
        #expect(diffPatch["negotiated"] == nil)
    }

    @Test("marking diff patches unnegotiated touches only the patch payloads")
    func markingUnnegotiatedTouchesOnlyPatches() throws {
        let patch = ACPDiffPatchPayload(version: 1, format: "git_patch", text: "@@ -1 +1 @@\n-a\n+b\n")
        let content: [ACPToolCallContent] = [
            .content(.text("hello")),
            .diff(path: "/repo/a.txt", oldText: nil, newText: "", kind: "update", diffStats: nil, patch: patch),
            .terminal(terminalId: "term-1"),
        ]
        let acknowledgements = Mutex(0)
        let params = ACPSessionUpdateParams(
            sessionId: "s1",
            update: .toolCallUpdate(.init(toolCallId: "tc", status: "completed", content: content)),
            durableConsumptionAcknowledgement: { acknowledgements.withLock { $0 += 1 } })

        let markedParams = params.markingDiffPatchesUnnegotiated()
        #expect(markedParams.sessionId == "s1")
        markedParams.durableConsumptionAcknowledgement?()
        #expect(acknowledgements.withLock { $0 } == 1)
        guard case .toolCallUpdate(let marked) = markedParams.update else {
            Issue.record("expected .toolCallUpdate")
            return
        }
        #expect(marked.toolCallId == "tc")
        #expect(marked.status == "completed")
        let items = try #require(marked.content)
        #expect(items.count == 3)
        #expect(items[0] == .content(.text("hello")))
        #expect(items[2] == .terminal(terminalId: "term-1"))
        guard case .diff(let path, _, _, let kind, _, let markedPatch) = items[1] else {
            Issue.record("expected .diff")
            return
        }
        #expect(path == "/repo/a.txt")
        #expect(kind == "update")
        #expect(markedPatch?.negotiated == false)
        #expect(markedPatch?.text == patch.text)

        let meta = AnyCodable(["permission": AnyCodable(["version": AnyCodable(1)] as [String: AnyCodable])])
        let options = [ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once")]
        let request = ACPPermissionRequestParams(
            sessionId: "s1", toolCall: .init(toolCallId: "tc", title: "Edit", content: content),
            options: options, metadata: meta)
        let markedRequest = request.markingDiffPatchesUnnegotiated()
        #expect(markedRequest.sessionId == "s1")
        #expect(markedRequest.options == options)
        #expect(markedRequest.metadata == meta)
        #expect(markedRequest.toolCall.title == "Edit")
        guard case .diff(_, _, _, _, _, let requestPatch)? = markedRequest.toolCall.content?[1] else {
            Issue.record("expected .diff")
            return
        }
        #expect(requestPatch?.negotiated == false)
        #expect(markedRequest.toolCall.content?[0] == .content(.text("hello")))
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
