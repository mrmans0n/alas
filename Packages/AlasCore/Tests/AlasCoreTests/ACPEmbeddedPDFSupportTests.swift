import Foundation
import Testing
import AlasCore

struct ACPEmbeddedPDFSupportTests {
    private static let claude = "@alas-ide/claude-agent-acp"

    private static let gates: [(name: String?, version: String, embeddedContext: Bool, expected: Bool)] = [
        (claude, "0.101.0-alas.1", true, true),
        (claude, "0.101.0-alas.2", true, true),
        (claude, "0.101.0-alas.10", true, true),
        (claude, "0.101.1-alas.1", true, true),
        (claude, "0.102.0-alas.1", true, true),
        (claude, "1.0.0-alas.1", true, true),
        (claude, "0.101.0-alas.0", true, false),
        (claude, "0.100.9-alas.9", true, false),
        (claude, "0.99.0-alas.1", true, false),
        (claude, "0.101.0", true, false),
        (claude, "0.101.0-rc.1", true, false),
        (claude, "0.101-alas.1", true, false),
        (claude, "", true, false),
        (claude, "newest", true, false),
        ("@agentclientprotocol/claude-agent-acp", "0.101.0-alas.1", true, false),
        ("@alas-ide/codex-acp", "2.5.0-alas.6", true, false),
        ("gemini", "9.9.9", true, false),
        (claude, "0.101.0-alas.1", false, false),
        (nil, "0.101.0-alas.1", true, false),
    ]

    @Test("gates on the fork's name, its verified version floor, and embeddedContext", arguments: gates)
    func gatesByIdentity(name: String?, version: String, embeddedContext: Bool, expected: Bool) {
        #expect(ACPEmbeddedPDFSupport.supports(
            agentInfo: name.map { ACPImplementationInfo(name: $0, version: version) },
            promptCapabilities: .init(embeddedContext: embeddedContext)) == expected)
    }
}

struct ACPPromptSizeGuardTests {
    /// Small, because the boundary doesn't depend on the number and scanning the
    /// real limit takes tens of seconds in a debug build on a busy CI runner.
    private static let limit = 4096

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

    @Test("allows a prompt of exactly the limit and refuses one byte more")
    func boundary() throws {
        func prompt(encodedSize size: Int) -> [ACPContentBlock] {
            func block(_ blob: String) -> ACPContentBlock {
                .blobResource(uri: "file:///a.pdf", mimeType: "application/pdf", blob: blob)
            }
            return [block(String(repeating: "x", count: size - ACPPromptSizeGuard.encodedSize(of: [block("")])))]
        }
        let atLimit = prompt(encodedSize: Self.limit)
        try ACPPromptSizeGuard.check(atLimit, limit: Self.limit)
        #expect(throws: ACPPromptRefusal.promptTooLarge(encodedBytes: Self.limit + 1)) {
            try ACPPromptSizeGuard.check(prompt(encodedSize: Self.limit + 1), limit: Self.limit)
        }
    }

    @Test("blames the fork context only when it alone is over the limit, since nothing the user removes can help")
    func blamesForkContextOnlyWhenItCannotFit() {
        let half = String(repeating: "x", count: Self.limit / 2 + 1)
        #expect(throws: ACPPromptRefusal.promptTooLarge(encodedBytes: ACPPromptSizeGuard.encodedSize(of: [.text(half), .text(half)]))) {
            try ACPPromptSizeGuard.check([.text(half), .text(half)], forkContext: half, limit: Self.limit)
        }
        let whole = String(repeating: "x", count: Self.limit)
        #expect(throws: ACPPromptRefusal.forkContextTooLarge(encodedBytes: ACPPromptSizeGuard.encodedSize(of: [.text(whole)]))) {
            try ACPPromptSizeGuard.check([.text(whole)], forkContext: whole, limit: Self.limit)
        }
    }

    @Test("a refusal is never read as an auth failure, whatever the file is called")
    func refusalIsNotAnAuthFailure() {
        #expect(ACPAuthFailure.message(from: ACPPromptRefusal.pdfMissing(name: "login required.pdf")) == nil)
    }
}
