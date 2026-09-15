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

    @Test("invalid signature and parameter indices fall back to the first available entries")
    func defaultsInvalidIndices() throws {
        let raw = Data(#"{"signatures":[{"label":"f(a)","parameters":[{"label":"a"}]}],"activeSignature":2,"activeParameter":4}"#.utf8)
        let help = try JSONDecoder().decode(LSPSignatureHelp.self, from: raw)
        #expect(SignatureHelpFeature.activeSignatureIndex(in: help) == 0)
        #expect(SignatureHelpFeature.activeParameter(in: help) == 0)
        #expect(SignatureHelpFeature.activeSignatureIndex(in: LSPSignatureHelp(signatures: [], activeSignature: nil, activeParameter: nil)) == nil)
    }

    @Test("omitted active indices default to the first signature parameter")
    func defaultsOmittedIndices() {
        let help = LSPSignatureHelp(
            signatures: [LSPSignatureInformation(
                label: "f(a, b)", documentation: nil,
                parameters: [
                    LSPSignatureParameter(label: .string("a"), documentation: nil),
                    LSPSignatureParameter(label: .string("b"), documentation: nil)
                ],
                activeParameter: nil
            )],
            activeSignature: nil,
            activeParameter: nil
        )
        #expect(SignatureHelpFeature.activeSignatureIndex(in: help) == 0)
        #expect(SignatureHelpFeature.activeParameter(in: help) == 0)
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
        let initialize = try #require(transport.sent.first)
        #expect(initialize.contains(#""contextSupport":true"#))
        #expect(!initialize.contains(#""activeSignatureHelpSupport""#))
        #expect(initialize.contains(#""activeParameterSupport":true"#))
        let help = try await client.signatureHelp(
            uri: "file:///tmp/f.swift",
            position: LSPPosition(line: 2, character: 8),
            context: LSPSignatureHelpContext(
                triggerKind: .triggerCharacter,
                triggerCharacter: ",",
                isRetrigger: true,
                activeSignatureHelp: LSPSignatureHelp(
                    signatures: [LSPSignatureInformation(label: "f(a)", documentation: nil, parameters: nil, activeParameter: nil)],
                    activeSignature: 0,
                    activeParameter: nil
                )
            )
        )
        let request = transport.sent.last ?? ""
        #expect(request.contains(#""method":"textDocument/signatureHelp""#))
        #expect(request.contains(#""triggerKind":2"#))
        #expect(request.contains(#""triggerCharacter":",""#))
        #expect(request.contains(#""isRetrigger":true"#))
        let requestObject = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        let requestParams = try #require(requestObject["params"] as? [String: Any])
        let requestContext = try #require(requestParams["context"] as? [String: Any])
        let activeHelp = try #require(requestContext["activeSignatureHelp"] as? [String: Any])
        #expect(activeHelp["activeSignature"] as? Int == 0)
        #expect((activeHelp["signatures"] as? [[String: Any]])?.first?["label"] as? String == "f(a)")
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
        ) == LSPSignatureHelpContext(triggerKind: .triggerCharacter, triggerCharacter: "(", isRetrigger: false, activeSignatureHelp: nil))
        #expect(SignatureHelpFeature.requestContext(
            text: "outer(inner(a,",
            caret: 14,
            triggerCharacters: ["("],
            retriggerCharacters: [","],
            isVisible: true
        ) == LSPSignatureHelpContext(triggerKind: .triggerCharacter, triggerCharacter: ",", isRetrigger: true, activeSignatureHelp: nil))
        #expect(SignatureHelpFeature.requestContext(
            text: "outer(inner(a,",
            caret: 14,
            triggerCharacters: ["("],
            retriggerCharacters: [","],
            isVisible: false
        ) == nil)
    }

    @Test("closing an inner call requests the enclosing call context")
    func tracksNestedCallContext() {
        #expect(SignatureHelpFeature.callStart(text: "outer(inner(a)", caret: 14) == 5)
        #expect(SignatureHelpFeature.callStart(text: "outer(inner(a),", caret: 15) == 5)
        #expect(SignatureHelpFeature.callStart(text: "outer(inner(a))", caret: 15) == nil)
        #expect(SignatureHelpFeature.contentChangeContext(
            text: "outer(inner(a),",
            caret: 15,
            previousCallStart: 11,
            isVisible: true
        ) == LSPSignatureHelpContext(triggerKind: .contentChange, triggerCharacter: nil, isRetrigger: true, activeSignatureHelp: nil))
    }

    @Test("mixed parameter label forms still locate a later string label")
    func locatesMixedParameterLabelRange() {
        let signature = LSPSignatureInformation(
            label: "f(alpha, beta)",
            documentation: nil,
            parameters: [
                LSPSignatureParameter(label: .offsets(start: 2, end: 7), documentation: nil),
                LSPSignatureParameter(label: .string("beta"), documentation: nil)
            ],
            activeParameter: nil
        )
        #expect(SignatureHelpFeature.parameterRange(in: signature, index: 1) == NSRange(location: 9, length: 4))
    }

    @Test("a current empty response dismisses existing help while stale responses remain ignored")
    func dismissesForCurrentEmptyResponse() {
        let textView = makeTextView("f(")
        let feature = SignatureHelpFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/f.swift" },
            isEnabled: { true }
        )
        let response = LSPSignatureHelp(
            signatures: [LSPSignatureInformation(label: "f(value)", documentation: nil, parameters: nil, activeParameter: nil)],
            activeSignature: 0,
            activeParameter: nil
        )

        feature.testingApplyCurrentResponse(response, caret: 2)
        #expect(feature.testingSnapshot.help == response)
        feature.testingApplyCurrentResponse(nil, caret: 2)
        #expect(feature.testingSnapshot.help == nil)
        #expect(!SignatureHelpFeature.isResponseCurrent(requestID: 1, currentRequestID: 2, contextIsCurrent: true))
    }

    @Test("manual feature request reaches the client and retains handlers through cancellation")
    func manualFeatureRequestAndRebindSafeCancellation() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        transport.onSend = { sent in
            guard sent.contains(#""method":"textDocument/signatureHelp""#) else { return }
            transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"signatures":[{"label":"f(value)"}],"activeSignature":0}}"#)
        }
        let textView = makeTextView("f(")
        let feature = SignatureHelpFeature(
            textView: textView,
            getClient: { client },
            getURI: { "file:///tmp/f.swift" },
            isEnabled: { true }
        )
        textView.signatureHelpManualTriggerHandler?()
        for _ in 0 ..< 100 {
            if feature.testingSnapshot.help != nil { break }
            await Task.yield()
        }

        #expect(feature.testingSnapshot.help?.signatures.first?.label == "f(value)")
        feature.cancelAndDismiss()
        #expect(textView.signatureHelpManualTriggerHandler != nil)
        #expect(textView.signatureHelpChangeHandler != nil)
        transport.finish()
    }

    @Test("manual requests are invoked and stale responses are ignored")
    func manualAndStaleRequestBehavior() {
        #expect(SignatureHelpFeature.manualRequestContext == LSPSignatureHelpContext(triggerKind: .invoked, triggerCharacter: nil, isRetrigger: false, activeSignatureHelp: nil))
        #expect(!SignatureHelpFeature.isResponseCurrent(requestID: 3, currentRequestID: 4, contextIsCurrent: true))
        #expect(!SignatureHelpFeature.isResponseCurrent(requestID: 4, currentRequestID: 4, contextIsCurrent: false))
        #expect(SignatureHelpFeature.isResponseCurrent(requestID: 4, currentRequestID: 4, contextIsCurrent: true))
    }

    private func makeTextView(_ text: String) -> CodeTextView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return textView
    }
}
