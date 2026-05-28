import Foundation
import Testing
@testable import Alas

@Suite("ACPComposerDraft")
struct ACPComposerDraftTests {
    @Test("codable round trip preserves ordered text and mention segments")
    func codableRoundTrip() throws {
        let draft = ACPComposerDraft(segments: [
            .text("Please inspect "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text("\nThen explain the bug.")
        ])

        let data = try JSONEncoder().encode(draft)
        let decoded = try JSONDecoder().decode(ACPComposerDraft.self, from: data)

        #expect(decoded == draft)
    }

    @Test("empty only when it has no meaningful storage segments")
    func emptyState() {
        #expect(ACPComposerDraft.empty.isEmpty)
        #expect(ACPComposerDraft(segments: [.text("")]).isEmpty)
        #expect(!ACPComposerDraft(segments: [.text(" ")]).isEmpty)
        #expect(!ACPComposerDraft(segments: [.mention(displayName: "a.swift", uri: "file:///a.swift")]).isEmpty)
    }
}
