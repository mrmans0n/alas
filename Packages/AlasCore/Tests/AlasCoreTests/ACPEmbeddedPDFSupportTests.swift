import Foundation
import Testing
import AlasCore

struct ACPEmbeddedPDFSupportTests {
    private static let claude = "@alas-ide/claude-agent-acp"

    @Test("gates on the fork's name and verified version floor", arguments: [
        (claude, "0.101.0-alas.1", true),
        (claude, "0.101.0-alas.2", true),
        (claude, "0.101.0-alas.10", true),
        (claude, "0.101.1-alas.1", true),
        (claude, "0.102.0-alas.1", true),
        (claude, "1.0.0-alas.1", true),
        (claude, "0.101.0-alas.0", false),
        (claude, "0.100.9-alas.9", false),
        (claude, "0.99.0-alas.1", false),
        (claude, "0.101.0", false),
        (claude, "0.101.0-rc.1", false),
        (claude, "0.101-alas.1", false),
        (claude, "", false),
        (claude, "newest", false),
        ("@agentclientprotocol/claude-agent-acp", "0.101.0-alas.1", false),
        ("@alas-ide/codex-acp", "2.5.0-alas.6", false),
        ("gemini", "9.9.9", false),
    ])
    func gatesByIdentity(name: String, version: String, expected: Bool) {
        #expect(ACPEmbeddedPDFSupport.supports(
            agentInfo: .init(name: name, version: version),
            promptCapabilities: .init(embeddedContext: true)) == expected)
    }

    @Test("needs embeddedContext and a known adapter")
    func needsCapabilityAndIdentity() {
        let eligible = ACPImplementationInfo(name: Self.claude, version: "0.101.0-alas.1")
        #expect(!ACPEmbeddedPDFSupport.supports(agentInfo: eligible, promptCapabilities: .init(embeddedContext: false)))
        #expect(!ACPEmbeddedPDFSupport.supports(agentInfo: nil, promptCapabilities: .init(embeddedContext: true)))
    }
}

struct ACPPromptSizeGuardTests {
    private static let limit = ACPPromptSizeGuard.maxEncodedBytes

    /// The characters JSON escapes, a raw one that it does not, and multi-byte text.
    private static let tricky = #"a"b\c/d+e"# + "\n\t\r\u{8}\u{C}\u{1}\u{7F} é 日本"

    @Test("measures exactly what the transport's encoder writes", arguments: [
        [ACPContentBlock.text(tricky)],
        [.blobResource(uri: "file:///a%20b/c.pdf", mimeType: "application/pdf", blob: "ab/c+d/==")],
        [.image(data: "ab/c+d==", uri: nil, mimeType: "image/png")],
        [.image(data: nil, uri: "file:///a.png", mimeType: "image/png")],
        [.resource(uri: "file:///a.txt", mimeType: nil, text: tricky)],
        [.resourceLink(uri: "file:///a.txt", name: tricky)],
        [],
        [.text(tricky), .blobResource(uri: "u", mimeType: nil, blob: "x/y"), .text("")],
    ])
    func measuresExactly(blocks: [ACPContentBlock]) throws {
        #expect(ACPPromptSizeGuard.encodedSize(of: blocks) == (try JSONEncoder().encode(blocks).count))
    }

    enum PayloadKind: CaseIterable, Sendable {
        case text, blob, image

        func block(_ payload: String) -> ACPContentBlock {
            switch self {
            case .text: .text(payload)
            case .blob: .blobResource(uri: "file:///a.pdf", mimeType: "application/pdf", blob: payload)
            case .image: .image(data: payload, uri: nil, mimeType: "image/png")
            }
        }

        func prompt(encodedSize size: Int) -> [ACPContentBlock] {
            let overhead = ACPPromptSizeGuard.encodedSize(of: [block("")])
            return [block(String(repeating: "x", count: size - overhead))]
        }
    }

    @Test("allows a prompt of exactly the limit and refuses one byte more", arguments: PayloadKind.allCases)
    func boundary(kind: PayloadKind) throws {
        let atLimit = kind.prompt(encodedSize: Self.limit)
        #expect(try JSONEncoder().encode(atLimit).count == Self.limit)
        try ACPPromptSizeGuard.check(atLimit)
        #expect(throws: ACPPromptRefusal.promptTooLarge(encodedBytes: Self.limit + 1)) {
            try ACPPromptSizeGuard.check(kind.prompt(encodedSize: Self.limit + 1))
        }
    }

    @Test("a base64 slash counts twice, because the encoder escapes it")
    func countsEscapedSlashes() {
        let blob = String(repeating: "/", count: Self.limit / 2 + 1)
        #expect(throws: ACPPromptRefusal.self) {
            try ACPPromptSizeGuard.check([.blobResource(uri: "u", mimeType: nil, blob: blob)])
        }
    }

    @Test("a refusal is never read as an auth failure, whatever the file is called")
    func refusalIsNotAnAuthFailure() {
        #expect(ACPAuthFailure.message(from: ACPPromptRefusal.pdfMissing(name: "login required.pdf")) == nil)
    }
}
