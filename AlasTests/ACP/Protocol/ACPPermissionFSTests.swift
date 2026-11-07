import Foundation
import Testing
@testable import Alas

@Suite("ACP permission + filesystem")
struct ACPPermissionFSTests {
    @Test("decodes a permission request")
    func permission() throws {
        let data = try fixture("permission-request")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPPermissionRequestParams>.self, from: data)
        let p = try #require(env.params)
        #expect(p.sessionId == "sess-abc")
        #expect(p.toolCall.toolCallId == "tc-9")
        #expect(p.options.count == 3)
        #expect(p.options[0].kind == "allow_once")
    }

    @Test("adapters without _meta decode a nil presentation and render as today")
    func noMetaYieldsNilPresentation() throws {
        let data = try fixture("permission-request")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPPermissionRequestParams>.self, from: data)
        let p = try #require(env.params)
        #expect(p.metadata == nil)
        #expect(ACPPermissionPresentation(metadata: p.metadata) == nil)
        #expect(p.options[0].presentationDescription == nil)
        #expect(p.toolCall.mcpServerName == nil)
    }

    @Test("decodes permission hints")
    func decodesPermissionPresentation() throws {
        let data = try fixture("permission-request-meta")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPPermissionRequestParams>.self, from: data)
        let p = try #require(env.params)
        let presentation = try #require(ACPPermissionPresentation(metadata: p.metadata))
        #expect(presentation.title == "Run command?")
        #expect(presentation.description == "Reason: needs shell access to build the project")
        #expect(presentation.defaultToNo == true)

        #expect(p.options.count == 3)
        #expect(p.options[0].presentationDescription == "Run this command one time")
        #expect(p.options[1].presentationDescription == nil) // no _meta on this option
        #expect(p.options[2].presentationDescription == "Don't run this command")

        #expect(p.toolCall.mcpServerName == "github")
    }

    @Test("permission card content folds _meta and the command block into rendered fields")
    func cardContentFromParams() throws {
        let data = try fixture("permission-request-meta")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPPermissionRequestParams>.self, from: data)
        let p = try #require(env.params)

        let content = ACPPermissionCardContent(params: p)
        #expect(content.heading == "Run command?")
        #expect(content.kind == "execute")
        #expect(content.title == "bash")
        #expect(content.summary == "swift build")
        #expect(content.reason == "Reason: needs shell access to build the project")
        #expect(content.defaultToNo)
        #expect(content.mcpServerName == "github")
        #expect(content.options.map(\.optionId) == ["allow-once", "allow-with-updates", "reject"])
        #expect(content.options.map(\.description) == ["Run this command one time", nil, "Don't run this command"])
    }

    /// Display hints never change what the user can decide: the options keep
    /// their ids and order, whatever the metadata says.
    @Test("presentation reads the negotiated record, then the legacy one, then none", arguments: [
        (#"{"permissionPresentation":{"version":1,"title":"new","description":"why","defaultToNo":true}}"#, "new", "why", true),
        (#"{"permissionPresentation":{"version":1,"title":"new"},"permission":{"version":1,"title":"old"}}"#, "new", nil, false),
        (#"{"permissionPresentation":{"version":2,"title":"future"},"permission":{"version":1,"title":"old"}}"#, "old", nil, false),
        (#"{"permission":{"version":1,"title":"old","description":"was"}}"#, "old", "was", false),
        (#"{"permissionPresentation":{"version":2,"title":"future"}}"#, nil, nil, false),
        (#"{"permissionPresentation":true,"permission":"x"}"#, nil, nil, false),
        (#"{"permissionPresentation":{"version":1,"title":7,"description":[],"defaultToNo":"yes"}}"#, nil, nil, false),
        (#"{"jetbrains":{"air":{"version":1,"permission":{"version":1,"title":"air"}}}}"#, nil, nil, false),
        (#""not an object""#, nil, nil, false),
    ] as [(String, String?, String?, Bool)])
    func presentationFallback(meta: String, heading: String?, reason: String?, defaultToNo: Bool) throws {
        let json = #"""
        {"sessionId":"s","toolCall":{"toolCallId":"t","title":"npm test"},"options":[
          {"optionId":"a","name":"Same","kind":"allow_once","_meta":\#(meta)},
          {"optionId":"b","name":"Same","kind":"reject_once","_meta":\#(meta)}
        ],"_meta":\#(meta)}
        """#
        let params = try JSONDecoder().decode(ACPPermissionRequestParams.self, from: Data(json.utf8))
        let content = ACPPermissionCardContent(params: params)
        #expect(content.heading == heading)
        #expect(content.reason == reason)
        #expect(content.defaultToNo == defaultToNo)
        #expect(content.options.map(\.optionId) == ["a", "b"])
        #expect(content.options.map(\.kind) == ["allow_once", "reject_once"])
        #expect(content.options.map(\.description) == [reason, reason])
    }

    @Test("a heading that repeats the tool call's title is dropped")
    func headingRepeatingTitle() throws {
        let json = #"""
        {"sessionId":"s","toolCall":{"toolCallId":"t","title":"npm test"},"options":[],
         "_meta":{"permissionPresentation":{"version":1,"title":"npm test"}}}
        """#
        let params = try JSONDecoder().decode(ACPPermissionRequestParams.self, from: Data(json.utf8))
        #expect(ACPPermissionCardContent(params: params).heading == nil)
    }

    struct DiffPreviewCase: CustomTestStringConvertible, Sendable {
        let name: String
        let requestContent: [ACPToolCallContent]?
        let rowDiffs: [ACPToolCallDiff]?
        let paths: [String]
        var testDescription: String { name }
    }

    nonisolated static func previewPatch(_ name: String) -> String {
        """
        diff --git a/repo/\(name) b/repo/\(name)
        --- a/repo/\(name)
        +++ b/repo/\(name)
        @@ -1 +1 @@
        -a
        +b

        """
    }

    nonisolated static let requestPatch: [ACPToolCallContent] = [.diff(
        path: "/repo/a.txt", oldText: nil, newText: "", kind: nil, diffStats: nil,
        patch: .init(version: 1, format: "git_patch", text: previewPatch("a.txt")))]

    nonisolated static let rowPatch = [ACPToolCallDiff.make(
        path: "/repo/b.txt", payload: .init(version: 1, format: "git_patch", text: previewPatch("b.txt")),
        source: .toolCall)]

    nonisolated static let diffPreviewCases: [DiffPreviewCase] = [
        .init(name: "request patch, no row", requestContent: requestPatch, rowDiffs: nil, paths: ["a.txt"]),
        .init(name: "Codex: no content, started row", requestContent: nil, rowDiffs: rowPatch, paths: ["b.txt"]),
        .init(name: "request patch wins over the row", requestContent: requestPatch, rowDiffs: rowPatch,
              paths: ["a.txt"]),
        .init(name: "neither", requestContent: nil, rowDiffs: nil, paths: []),
    ]

    @Test("the approval card previews the request's patch, else the row's, and never changes the answers",
          arguments: diffPreviewCases)
    func cardContentDiffPreview(_ row: DiffPreviewCase) {
        let metadata = AnyCodable([
            "permission": AnyCodable([
                "version": AnyCodable(1),
                "defaultToNo": AnyCodable(true),
            ] as [String: AnyCodable]),
        ] as [String: AnyCodable])
        let options = [
            ACPPermissionOption(optionId: "allow", name: "Allow", kind: "allow_once"),
            ACPPermissionOption(optionId: "reject", name: "Reject", kind: "reject_once"),
        ]
        func params(_ content: [ACPToolCallContent]?) -> ACPPermissionRequestParams {
            ACPPermissionRequestParams(
                sessionId: "s",
                toolCall: ACPPermissionToolCall(toolCallId: "tc-edit", title: "Edit", kind: "edit", content: content),
                options: options, metadata: metadata)
        }
        let existing = row.rowDiffs.map {
            ACPMessage.ToolCall(toolCallId: "tc-edit", title: "Edit", status: "in_progress", diffs: $0)
        }

        let content = ACPPermissionCardContent(
            params: params(row.requestContent), existingToolCall: existing, worktreeRoot: "/repo")
        #expect(content.diffSections.map(\.path) == row.paths)
        #expect(content.diffSections.allSatisfy { $0.label == .proposed })

        let bare = ACPPermissionCardContent(params: params(nil))
        #expect(content.options == bare.options)
        #expect(content.defaultToNo == bare.defaultToNo)
        #expect(bare.defaultToNo)
    }

    @Test("unversioned/future _meta.permission is ignored, not surfaced")
    func ignoresUnversionedOrFutureMeta() throws {
        let futureVersion = AnyCodable([
            "permission": AnyCodable([
                "version": AnyCodable(2),
                "title": AnyCodable("From a future schema"),
            ] as [String: AnyCodable]),
        ] as [String: AnyCodable])
        #expect(ACPPermissionPresentation(metadata: futureVersion) == nil)

        let missingVersion = AnyCodable([
            "permission": AnyCodable([
                "title": AnyCodable("No version tag"),
            ] as [String: AnyCodable]),
        ] as [String: AnyCodable])
        #expect(ACPPermissionPresentation(metadata: missingVersion) == nil)

        let unrelatedKey = AnyCodable([
            "someOtherExtension": AnyCodable(["foo": AnyCodable("bar")] as [String: AnyCodable]),
        ] as [String: AnyCodable])
        #expect(ACPPermissionPresentation(metadata: unrelatedKey) == nil)
    }

    @Test("decodes fs/write_text_file")
    func fsWrite() throws {
        let data = try fixture("fs-write")
        let env = try JSONDecoder().decode(JSONRPCEnvelope<ACPFsWriteParams>.self, from: data)
        #expect(env.params?.path == "/Users/me/proj/foo.txt")
        #expect(env.params?.content == "hi")
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: ACPPermissionFixtureMarker.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }
}

private final class ACPPermissionFixtureMarker {}
