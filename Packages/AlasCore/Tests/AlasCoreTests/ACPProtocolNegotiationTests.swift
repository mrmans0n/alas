import Foundation
import Testing
import AlasCore

struct ACPProtocolNegotiationTests {
    @Test(arguments: [-1, 0, 2, 3])
    func rejectsAnUnrequestedProtocolVersion(selected: Int) async {
        let client = ACPMockClient()
        client.script(method: "initialize") { _ in
            Data("{\"protocolVersion\":\(selected)}".utf8)
        }
        let connection = ACPConnection(client: client)
        await #expect(throws: ACPProtocolNegotiationError.unsupportedVersion(
            requested: 1, selected: selected, supported: [1])) {
            try await connection.initialize()
        }
        #expect(connection.negotiatedProtocolVersion == nil)
        #expect(client.sent.count == 1)
    }

    @Test func downgradedInitializationUsesTheV1Schema() throws {
        let result = try ACPInitializationResult.decode(
            from: Data(#"{"protocolVersion":1,"agentInfo":{"name":"legacy","version":"1.2"},"agentCapabilities":{"promptCapabilities":{"image":true}}}"#.utf8),
            requestedVersion: .v2, supportedVersions: [.v1, .v2])
        guard case .v1(let legacy) = result else {
            Issue.record("A negotiated v1 response must use the v1 decoder")
            return
        }
        #expect(legacy.agentInfo?.name == "legacy")
        #expect(legacy.agentCapabilities?.promptCapabilities?.image == true)
    }

    @Test func v2RequestUsesItsOwnIdentityAndCapabilityShape() throws {
        let params = ACPV2InitializeParams(
            info: .init(name: "alas", version: "test"),
            capabilities: ["elicitation": ["form": .object([:])]])
        let raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any])
        #expect(Set(raw.keys) == ["protocolVersion", "info", "capabilities"])
        #expect(raw["protocolVersion"] as? Int == 2)
        #expect(raw["info"] as? [String: String] == ["name": "alas", "version": "test"])
        let capabilities = try #require(raw["capabilities"] as? [String: Any])
        let elicitation = try #require(capabilities["elicitation"] as? [String: Any])
        #expect((elicitation["form"] as? [String: Any])?.isEmpty == true)
    }

    @Test(arguments: [("{}", true), ("null", false), ("true", false)])
    func v2CapabilitiesRequireObjectMarkersAndKeepUnknownData(marker: String, supported: Bool) throws {
        let result = try ACPInitializationResult.decode(
            from: Data("""
            {"protocolVersion":2,"info":{"name":"agent","version":"2"},
             "capabilities":{"session":{"prompt":{"image":\(marker)}}},
             "authMethods":[{"type":"_future","methodId":"future","name":"Future"}],
             "futureField":{"keep":true}}
            """.utf8), requestedVersion: .v2, supportedVersions: [.v1, .v2])
        guard case .v2(let v2) = result, case .object(let raw) = v2.rawValue else {
            Issue.record("A negotiated v2 response must remain separate from v1 capabilities")
            return
        }
        #expect(v2.info == .init(name: "agent", version: "2"))
        #expect((v2.capability(at: ["session", "prompt", "image"]) != nil) == supported)
        #expect(v2.capability(at: ["session", "mcp"]) == nil)
        #expect(raw["futureField"] == .object(["keep": .bool(true)]))
        #expect(raw["authMethods"] == .array([.object([
            "type": .string("_future"), "methodId": .string("future"), "name": .string("Future")])]))
    }

    @Test(arguments: [
        #"{}"#, #"{"protocolVersion":true}"#, #"{"protocolVersion":"2"}"#,
        #"{"protocolVersion":1.5}"#, #"{"protocolVersion":2}"#,
        #"{"protocolVersion":2,"info":{"name":"agent","version":false}}"#,
    ])
    func malformedBootstrapCannotBecomeAConnection(json: String) {
        #expect(throws: DecodingError.self) {
            try ACPInitializationResult.decode(
                from: Data(json.utf8), requestedVersion: .v2, supportedVersions: [.v1, .v2])
        }
    }

    @Test func v2CannotBeSelectedAboveTheRequestedVersion() {
        #expect(throws: ACPProtocolNegotiationError.unsupportedVersion(requested: 1, selected: 2, supported: [1, 2])) {
            try ACPInitializationResult.decode(
                from: Data(#"{"protocolVersion":2}"#.utf8), requestedVersion: .v1, supportedVersions: [.v1, .v2])
        }
    }

    @Test func changedPreferenceOnlyAffectsNewConnectionSnapshots() async throws {
        var config = AppConfig.defaults
        let originalClient = ACPMockClient()
        let nextClient = ACPMockClient()
        for client in [originalClient, nextClient] {
            client.script(method: "initialize") { request in
                let params = try #require(request.params as? ACPInitializeParams)
                #expect(params.protocolVersion == 1)
                #expect(params.clientCapabilities.fs.readTextFile)
                return Data(#"{"protocolVersion":1,"agentInfo":{"name":"agent","version":"1"}}"#.utf8)
            }
        }
        let original = ACPConnection(client: originalClient, protocolSelection: .init(
            experimentalV2Enabled: config.experimentalACP2Enabled))
        _ = try await original.initialize()
        config.experimentalACP2Enabled = true
        let next = ACPConnection(client: nextClient, protocolSelection: .init(
            experimentalV2Enabled: config.experimentalACP2Enabled))
        _ = try await next.initialize()
        #expect(!original.protocolSelection.experimentalV2Enabled)
        #expect(next.protocolSelection.experimentalV2Enabled)
        #expect(original.negotiatedProtocolVersion == .v1)
        #expect(next.negotiatedProtocolVersion == .v1)
        #expect(originalClient.sent.count == 1)
        #expect(nextClient.sent.count == 1)
    }
}
