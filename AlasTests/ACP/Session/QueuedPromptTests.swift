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

    @Test("scheduled date round-trips while legacy queue JSON decodes without one")
    func scheduledDateCompatibility() throws {
        let scheduledAt = Date(timeIntervalSince1970: 1_800_000_000)
        let prompt = QueuedPrompt(
            blocks: [.text("later")],
            enqueuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scheduledAt: scheduledAt
        )

        let decoded = try JSONDecoder().decode(
            QueuedPrompt.self,
            from: JSONEncoder().encode(prompt)
        )
        #expect(decoded.scheduledAt == scheduledAt)

        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","blocks":[{"type":"text","text":"legacy"}],"enqueuedAt":0,"status":"pending"}"#
        #expect(try JSONDecoder().decode(
            QueuedPrompt.self,
            from: Data(legacy.utf8)
        ).scheduledAt == nil)
    }

    @Test("a scheduled prompt becomes ready at its deadline")
    func scheduledPromptReadiness() {
        let deadline = Date(timeIntervalSince1970: 100)
        let prompt = QueuedPrompt(blocks: [.text("later")], scheduledAt: deadline)

        #expect(!prompt.isReady(at: Date(timeIntervalSince1970: 99)))
        #expect(prompt.isReady(at: deadline))
        #expect(prompt.isReady(at: Date(timeIntervalSince1970: 101)))
    }

    @Test("normalizeAfterRestore flips .sending to .pending; legacy sends become delivery-uncertain")
    func normalize() {
        let q = QueuedPrompt(id: UUID(), blocks: [.text("x")],
                             enqueuedAt: .init(), status: .sending, lastError: "boom")
        let n = q.normalizedAfterRestore()
        #expect(n.status == .pending)
        // A legacy mid-send row without dispatch provenance may have reached
        // the agent, so it is marked uncertain — while an existing, specific
        // error survives normalization.
        #expect(n.deliveryUncertain)
        #expect(n.lastError == "boom")

        // A legacy row with no prior error takes the uncertainty notice.
        let errored = QueuedPrompt(id: UUID(), blocks: [.text("x")],
                                   enqueuedAt: .init(), status: .sending, lastError: nil)
        let notified = errored.normalizedAfterRestore()
        #expect(notified.status == .pending)
        #expect(notified.deliveryUncertain)
        #expect(notified.lastError == QueuedPrompt.deliveryUncertaintyMessage)

        // Explicit provenance (or an opt-out) keeps the caller's lastError.
        let provenanced = QueuedPrompt(id: UUID(), blocks: [.text("x")],
                                       enqueuedAt: .init(), status: .sending, lastError: "boom")
        var withGeneration = provenanced
        withGeneration.dispatchedBrokerGeneration = ACPBrokerGeneration(rawValue: 1)
        let kept = withGeneration.normalizedAfterRestore()
        #expect(kept.status == .pending)
        #expect(!kept.deliveryUncertain)
        #expect(kept.lastError == "boom")

        let optedOut = provenanced.normalizedAfterRestore(markLegacySendingUncertain: false)
        #expect(optedOut.status == .pending)
        #expect(!optedOut.deliveryUncertain)
        #expect(optedOut.lastError == "boom")
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
            // `extract` emits "review " + "@File.swift " (the marker adds its own
            // trailing space) and the following text keeps its leading space in
            // " please" — hence the double space before "please".
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

    @Test("delegated provenance round-trips while legacy JSON remains valid")
    func delegatedProvenanceRoundTrip() throws {
        let source = ACPDelegatedPromptSource(sessionId: "parent", messageId: "message-1")
        let prompt = QueuedPrompt(
            id: UUID(), blocks: [.text("delegate")], enqueuedAt: .init(), delegatedSource: source)
        let data = try JSONEncoder().encode(prompt)
        #expect(try JSONDecoder().decode(QueuedPrompt.self, from: data).delegatedSource == source)

        let legacy = #"{"id":"00000000-0000-0000-0000-000000000001","blocks":[{"type":"text","text":"legacy"}],"enqueuedAt":0,"status":"pending"}"#
        #expect(try JSONDecoder().decode(QueuedPrompt.self, from: Data(legacy.utf8)).delegatedSource == nil)
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
