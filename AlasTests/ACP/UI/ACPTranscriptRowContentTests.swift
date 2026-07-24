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
