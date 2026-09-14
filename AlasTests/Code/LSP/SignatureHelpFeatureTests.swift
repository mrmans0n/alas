import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct SignatureHelpFeatureTests {
    @Test func selectsServerActiveParameter() throws {
        let raw = Data(#"{"signatures":[{"label":"f(a, b)","parameters":[{"label":"a"},{"label":"b"}]}],"activeSignature":0,"activeParameter":1}"#.utf8)
        let help = try JSONDecoder().decode(LSPSignatureHelp.self, from: raw)
        #expect(SignatureHelpFeature.activeParameter(in: help) == 1)
    }

    @Test("preserves string and offset parameter labels plus documentation")
    func decodesParameterLabelRepresentations() throws {
        let raw = Data(#"{"signatures":[{"label":"f(alpha, beta)","documentation":{"kind":"markdown","value":"Signature docs"},"parameters":[{"label":[2,7],"documentation":"Alpha docs"},{"label":"beta"}]}]}"#.utf8)
        let help = try JSONDecoder().decode(LSPSignatureHelp.self, from: raw)
        let signature = try #require(help.signatures.first)
        #expect(signature.documentation == .markup(kind: "markdown", value: "Signature docs"))
        #expect(signature.parameters?[0].label == .offsets(start: 2, end: 7))
        #expect(signature.parameters?[0].documentation == .plain("Alpha docs"))
        #expect(signature.parameters?[1].label == .string("beta"))
    }

    @Test("per-signature active parameter overrides help-level metadata")
    func usesPerSignatureActiveParameter() throws {
        let raw = Data(#"{"signatures":[{"label":"f(a, b)","activeParameter":0,"parameters":[{"label":"a"},{"label":"b"}]}],"activeParameter":1}"#.utf8)
        let help = try JSONDecoder().decode(LSPSignatureHelp.self, from: raw)
        #expect(SignatureHelpFeature.activeParameter(in: help) == 0)
    }

    @Test("invalid signature and parameter indices do not produce a selection")
    func rejectsInvalidIndices() throws {
        let raw = Data(#"{"signatures":[{"label":"f(a)","parameters":[{"label":"a"}]}],"activeSignature":2,"activeParameter":4}"#.utf8)
        let help = try JSONDecoder().decode(LSPSignatureHelp.self, from: raw)
        #expect(SignatureHelpFeature.activeSignatureIndex(in: help) == nil)
        #expect(SignatureHelpFeature.activeParameter(in: help) == nil)
        #expect(SignatureHelpFeature.activeSignatureIndex(in: LSPSignatureHelp(signatures: [], activeSignature: nil, activeParameter: nil)) == nil)
    }

    @Test("signature help capability is available only when advertised")
    func decodesSignatureHelpCapability() throws {
        let advertised = try LSPCapabilities(json: Data(#"{"signatureHelpProvider":{"triggerCharacters":["("]}}"#.utf8))
        let absent = try LSPCapabilities(json: Data("{}".utf8))
        #expect(advertised.supports(.signatureHelp))
        #expect(!absent.supports(.signatureHelp))
    }

    @Test("signature help requests carry trigger and retrigger context")
    func clientSendsContext() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"signatureHelpProvider":{"triggerCharacters":["("],"retriggerCharacters":[","]}}}}"#)
            } else if sent.contains(#""method":"textDocument/signatureHelp""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":{"signatures":[{"label":"f(a)"}]}}"#)
            }
        }
        try await client.initialize()
        let help = try await client.signatureHelp(
            uri: "file:///tmp/f.swift",
            position: LSPPosition(line: 2, character: 8),
            context: LSPSignatureHelpContext(
                triggerKind: .triggerCharacter,
                triggerCharacter: ",",
                isRetrigger: true
            )
        )
        let request = transport.sent.last ?? ""
        #expect(request.contains(#""method":"textDocument/signatureHelp""#))
        #expect(request.contains(#""triggerKind":2"#))
        #expect(request.contains(#""triggerCharacter":",""#))
        #expect(request.contains(#""isRetrigger":true"#))
        #expect(help?.signatures.map(\.label) == ["f(a)"])
        #expect(await client.signatureHelpTriggerCharacters == ["("])
        #expect(await client.signatureHelpRetriggerCharacters == [","])
        transport.finish()
    }

    @Test("nested calls classify configured trigger and retrigger characters")
    func classifiesNestedCallTriggers() {
        #expect(SignatureHelpFeature.requestContext(
            text: "outer(inner(",
            caret: 12,
            triggerCharacters: ["("],
            retriggerCharacters: [","],
            isVisible: false
        ) == LSPSignatureHelpContext(triggerKind: .triggerCharacter, triggerCharacter: "(", isRetrigger: false))
        #expect(SignatureHelpFeature.requestContext(
            text: "outer(inner(a,",
            caret: 14,
            triggerCharacters: ["("],
            retriggerCharacters: [","],
            isVisible: true
        ) == LSPSignatureHelpContext(triggerKind: .triggerCharacter, triggerCharacter: ",", isRetrigger: true))
    }

    @Test("manual requests are invoked and stale responses are ignored")
    func manualAndStaleRequestBehavior() {
        #expect(SignatureHelpFeature.manualRequestContext == LSPSignatureHelpContext(triggerKind: .invoked, triggerCharacter: nil, isRetrigger: false))
        #expect(!SignatureHelpFeature.isResponseCurrent(requestID: 3, currentRequestID: 4, contextIsCurrent: true))
        #expect(!SignatureHelpFeature.isResponseCurrent(requestID: 4, currentRequestID: 4, contextIsCurrent: false))
        #expect(SignatureHelpFeature.isResponseCurrent(requestID: 4, currentRequestID: 4, contextIsCurrent: true))
    }
}
