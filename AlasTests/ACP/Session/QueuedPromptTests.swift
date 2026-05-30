import Foundation
import Testing
@testable import Alas

@Suite("QueuedPrompt")
struct QueuedPromptTests {
    @Test("round-trips JSON with default status .pending")
    func roundTripDefault() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original = QueuedPrompt(
            id: id,
            blocks: [.text("hello"), .resourceLink(uri: "file:///a.txt", name: "a.txt")],
            enqueuedAt: date,
            status: .pending,
            lastError: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QueuedPrompt.self, from: data)
        #expect(decoded == original)
    }

    @Test("normalizeAfterRestore flips .sending to .pending and clears lastError untouched")
    func normalize() {
        let q = QueuedPrompt(id: UUID(), blocks: [.text("x")],
                             enqueuedAt: .init(), status: .sending, lastError: "boom")
        let n = q.normalizedAfterRestore()
        #expect(n.status == .pending)
        #expect(n.lastError == "boom")    // lastError survives; only status flips
    }

    @Test("encodes status as raw string")
    func statusRaw() throws {
        let q = QueuedPrompt(id: UUID(), blocks: [.text("x")],
                             enqueuedAt: .init(), status: .sending, lastError: nil)
        let json = String(data: try JSONEncoder().encode(q), encoding: .utf8)!
        #expect(json.contains("\"status\":\"sending\""))
    }

    @Test("draft round-trips through JSON when present")
    func draftRoundTrip() throws {
        let draft = ACPComposerDraft(segments: [
            .text("review "),
            .mention(displayName: "File.swift", uri: "file:///tmp/File.swift"),
            .text(" please")
        ])
        let original = QueuedPrompt(
            id: UUID(),
            // The "@File.swift " marker consumes one trailing space; " please" remains.
            blocks: [.text("review @File.swift  please"),
                     .resourceLink(uri: "file:///tmp/File.swift", name: "File.swift")],
            enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            draft: draft
        )
        let decoded = try JSONDecoder().decode(
            QueuedPrompt.self, from: try JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.draft == draft)
    }

    @Test("legacy JSON without a draft key decodes to nil")
    func legacyNoDraftKey() throws {
        let legacy = QueuedPrompt(
            id: UUID(), blocks: [.text("hi")],
            enqueuedAt: Date(timeIntervalSince1970: 1), status: .pending)
        let json = String(data: try JSONEncoder().encode(legacy), encoding: .utf8)!
        #expect(!json.contains("\"draft\""))   // nil optional is omitted on encode
        let decoded = try JSONDecoder().decode(
            QueuedPrompt.self, from: Data(json.utf8))
        #expect(decoded.draft == nil)
    }

    @Test("restorableDraft prefers the stored draft, else falls back to the blocks heuristic")
    func restorableDraftFallback() {
        let draft = ACPComposerDraft(segments: [.text("kept")])
        let withDraft = QueuedPrompt(id: UUID(), blocks: [.text("ignored")],
                                     enqueuedAt: .init(), draft: draft)
        #expect(withDraft.restorableDraft == draft)

        let blocks: [ACPContentBlock] = [.text("hello @File.swift "),
                                         .resourceLink(uri: "file:///File.swift", name: "File.swift")]
        let noDraft = QueuedPrompt(id: UUID(), blocks: blocks, enqueuedAt: .init())
        // Spell out the heuristic's expected output so this asserts a concrete
        // value, not a tautology against the same initializer.
        #expect(noDraft.restorableDraft == ACPComposerDraft(segments: [
            .text("hello "),
            .mention(displayName: "File.swift", uri: "file:///File.swift"),
        ]))
    }
}
