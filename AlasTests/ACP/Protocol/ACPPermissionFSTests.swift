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
