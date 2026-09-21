import Foundation
import Testing
@testable import Alas

@Suite("ACPAuthStatus")
struct ACPAuthStatusTests {
    @Test("decodes every known kind", arguments: [
        ("account", ACPAuthStatus.Kind.account),
        ("api_key", .apiKey),
        ("gateway", .gateway),
        ("external", .external),
        ("none", .none),
    ])
    func decodesKnownKind(wire: String, expected: ACPAuthStatus.Kind) throws {
        let data = Data("""
        { "kind": "\(wire)", "label": "Test Label" }
        """.utf8)

        let status = try JSONDecoder().decode(ACPAuthStatus.self, from: data)

        #expect(status.kind == expected)
        #expect(status.label == "Test Label")
    }

    @Test("decodes an unrecognised kind as unknown for forward compatibility")
    func decodesUnknownKind() throws {
        let data = Data("""
        { "kind": "future_kind", "label": "Future" }
        """.utf8)

        let status = try JSONDecoder().decode(ACPAuthStatus.self, from: data)

        #expect(status.kind == .unknown("future_kind"))
    }

    @Test("decodes a payload with only kind and label")
    func decodesMinimalPayload() throws {
        let data = Data("""
        { "kind": "none", "label": "Not logged in" }
        """.utf8)

        let status = try JSONDecoder().decode(ACPAuthStatus.self, from: data)

        #expect(status.kind == .none)
        #expect(status.label == "Not logged in")
        #expect(status.detail == nil)
        #expect(status.account == nil)
        #expect(status.vendor == nil)
    }

    @Test("decodes detail, account, and vendor when present")
    func decodesFullPayload() throws {
        let data = Data("""
        {
          "kind": "account",
          "label": "ChatGPT Pro",
          "detail": "Renews monthly",
          "account": {
            "email": "person@example.com",
            "organization": "Acme",
            "plan": "Pro"
          },
          "vendor": { "tier": 3 }
        }
        """.utf8)

        let status = try JSONDecoder().decode(ACPAuthStatus.self, from: data)

        #expect(status.kind == .account)
        #expect(status.label == "ChatGPT Pro")
        #expect(status.detail == "Renews monthly")
        #expect(status.account?.email == "person@example.com")
        #expect(status.account?.organization == "Acme")
        #expect(status.account?.plan == "Pro")
        #expect(status.vendor != nil)
    }

    @Test("decodes the _auth/status_update notification params")
    func decodesUpdateParams() throws {
        let data = Data("""
        { "authStatus": { "kind": "api_key", "label": "OpenAI API key" } }
        """.utf8)

        let params = try JSONDecoder().decode(ACPAuthStatusUpdateParams.self, from: data)

        #expect(params.authStatus.kind == .apiKey)
        #expect(params.authStatus.label == "OpenAI API key")
    }

    @Test("decodes a payload missing label without failing")
    func decodesMissingLabel() throws {
        let data = Data("""
        { "kind": "gateway" }
        """.utf8)

        let status = try JSONDecoder().decode(ACPAuthStatus.self, from: data)

        #expect(status.kind == .gateway)
        #expect(status.label == "")
    }
}
