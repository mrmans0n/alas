import Testing
import Foundation
import CoreGraphics
@testable import Alas

@Suite("ACPTranscriptRowContent equality")
struct ACPTranscriptRowContentTests {
    @Test("equality ignores closure identity")
    @MainActor
    func rowContentEqualityIgnoresClosureIdentity() {
        let msg = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        #expect(a == b)
    }

    @Test("equality detects fork action availability changes")
    @MainActor
    func rowContentEqualityDetectsForkAvailabilityChange() {
        let msg = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil,
            isForkEligible: false, forkTargets: [])
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil,
            isForkEligible: true, forkTargets: [])
        #expect(a != b)
    }

    @Test("row equality snapshots fork eligibility")
    @MainActor
    func rowContentEqualitySnapshotsForkEligibility() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let message = ACPMessage.user(id: UUID(), text: "hello", attachments: [])
        let targets: [ACPSessionForkTarget] = [
            .init(id: "claude", displayName: "Claude", isSameAgent: true)
        ]

        func row(isForkEligible: Bool) -> ACPTranscriptRowContent {
            ACPTranscriptRowContent(
                stableId: message.stableId,
                messageIndex: 0,
                message: message,
                messageCreatedAt: nil,
                messagePhase: ACPTranscriptRowContent.presentationPhase(of: message),
                contentMaxWidth: 800,
                typography: .default,
                trustedImageRoot: nil,
                transcript: session.transcript,
                session: session,
                onOpenDiff: { _ in },
                onLoadFullToolCallContent: { _ in nil },
                isForkEligible: isForkEligible,
                forkTargets: targets,
                onFork: { _, _ in }
            )
        }

        #expect(row(isForkEligible: false) != row(isForkEligible: true))
    }

    @Test("equality detects fork target changes")
    @MainActor
    func rowContentEqualityDetectsForkTargetChange() {
        let msg = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil,
            isForkEligible: true,
            forkTargets: [.init(id: "claude", displayName: "Claude", isSameAgent: true)])
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil,
            isForkEligible: true,
            forkTargets: [.init(id: "codex", displayName: "Codex", isSameAgent: true)])
        #expect(a != b)
    }

    @Test("equality detects a message change")
    @MainActor
    func rowContentEqualityDetectsMessageChange() {
        let msgA = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let msgB = ACPMessage.systemNotice(id: UUID(), text: "goodbye")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msgA, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msgB, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        #expect(a != b)
    }

    @Test("row equality detects a phase adopted by its streaming buffer")
    @MainActor
    func rowContentEqualityDetectsAdoptedPhase() {
        let session = ACPSession(id: "s", agentId: "codex", worktreeId: "w", title: "t")
        let buffer = StreamingText("working")
        let message = ACPMessage.agent(id: UUID(), messageId: "agent-1", buffer)

        func row() -> ACPTranscriptRowContent {
            ACPTranscriptRowContent(
                stableId: message.stableId,
                messageIndex: 0,
                message: message,
                messageCreatedAt: nil,
                messagePhase: ACPTranscriptRowContent.presentationPhase(of: message),
                contentMaxWidth: 800,
                typography: .default,
                trustedImageRoot: nil,
                transcript: session.transcript,
                session: session,
                onOpenDiff: { _ in },
                onLoadFullToolCallContent: { _ in nil },
                isForkEligible: false,
                forkTargets: [],
                onFork: { _, _ in }
            )
        }

        let before = row()
        buffer.adopt(
            phase: .commentary,
            metadata: AnyCodable(["codex": AnyCodable(["phase": AnyCodable("commentary")])]))
        let after = row()

        #expect(before != after)
    }

    @Test("equality detects a content-width change")
    @MainActor
    func rowContentEqualityDetectsWidthChange() {
        let msg = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 640,
            typography: .default, trustedImageRoot: nil)
        #expect(a != b)
    }

    @Test("equality detects available row width changes independently from content max width")
    @MainActor
    func rowContentEqualityDetectsAvailableRowWidthChange() {
        let msg = ACPMessage.user(id: UUID(), text: "hello", attachments: [])
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg,
            messageCreatedAt: Date(timeIntervalSince1970: 1),
            contentMaxWidth: 720,
            availableRowContentWidth: 720,
            typography: .default,
            trustedImageRoot: nil)
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg,
            messageCreatedAt: Date(timeIntervalSince1970: 1),
            contentMaxWidth: 720,
            availableRowContentWidth: 280,
            typography: .default,
            trustedImageRoot: nil)

        #expect(a != b)
        #expect(ACPTranscriptRowContent.showsInlineTimestamp(availableRowContentWidth: 720))
        #expect(!ACPTranscriptRowContent.showsInlineTimestamp(availableRowContentWidth: 280))
    }

    @Test("equality detects a message timestamp change")
    @MainActor
    func rowContentEqualityDetectsTimestampChange() {
        let message = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: message,
            messageCreatedAt: Date(timeIntervalSince1970: 1),
            contentMaxWidth: 800, typography: .default, trustedImageRoot: nil)
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: message,
            messageCreatedAt: Date(timeIntervalSince1970: 2),
            contentMaxWidth: 800, typography: .default, trustedImageRoot: nil)
        #expect(a != b)
    }

    @Test("equality detects a typography change")
    @MainActor
    func rowContentEqualityDetectsTypographyChange() {
        let msg = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: ACPChatTypography(fontFamily: "Menlo", fontSize: 15),
            trustedImageRoot: nil)
        #expect(a != b)
    }

    @Test("equality detects a stable-id change")
    @MainActor
    func rowContentEqualityDetectsStableIdChange() {
        let msg = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s2", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        #expect(a != b)
    }

    @Test("equality detects a trusted-image-root change")
    @MainActor
    func rowContentEqualityDetectsTrustedImageRootChange() {
        let msg = ACPMessage.systemNotice(id: UUID(), text: "hello")
        let a = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: nil)
        let b = ACPTranscriptRowContent.equalityKey(
            stableId: "s1", message: msg, contentMaxWidth: 800,
            typography: .default, trustedImageRoot: URL(fileURLWithPath: "/tmp"))
        #expect(a != b)
    }
}
