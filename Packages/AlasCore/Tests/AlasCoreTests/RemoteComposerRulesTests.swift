import Foundation
import Testing
@testable import AlasRemoteKit

struct RemoteComposerRulesTests {
    private func queued(canRemove: Bool? = nil, images: Int = 0, resources: Int = 0) -> RemoteQueuedPrompt {
        RemoteQueuedPrompt(id: UUID().uuidString, text: "t", imageCount: images, resourceCount: resources,
                           status: "pending", lastError: nil, scheduledAt: nil, canRemove: canRemove)
    }

    @Test(arguments: [
        (true, 0, 0, true), (nil, 0, 0, true), (false, 0, 0, false), (true, 1, 0, false), (true, 0, 2, false),
    ] as [(Bool?, Int, Int, Bool)])
    func queuedItemIsEditableOnlyWhenRemovableAndAttachmentFree(
        canRemove: Bool?, images: Int, resources: Int, expected: Bool
    ) {
        let item = queued(canRemove: canRemove, images: images, resources: resources)
        #expect(RemoteQueueRules.canEdit(item) == expected)
    }

    @Test func clearIsOfferedOnlyWhenSomeQueuedItemIsRemovable() {
        #expect(!RemoteQueueRules.canClear([queued(canRemove: false), queued(canRemove: false)]))
        #expect(RemoteQueueRules.canClear([queued(canRemove: false), queued(canRemove: nil)]))
    }

    @Test(arguments: [
        ("hello", 0, 0, "hello"),
        ("", 2, 0, "🖼 ×2"),
        ("", 0, 1, "📎 ×1"),
        ("see", 1, 3, "see\n🖼 ×1 📎 ×3"),
    ])
    func queuedItemsWithAttachmentsShowCountMarkers(text: String, images: Int, resources: Int, expected: String) {
        let item = RemoteQueuedPrompt(id: UUID().uuidString, text: text, imageCount: images,
                                      resourceCount: resources, status: "pending", lastError: nil, scheduledAt: nil)
        #expect(RemoteQueueRules.displayText(for: item) == expected)
    }

    @Test(arguments: [
        ("@", 1, 0, ""), ("see @Alas/Sources/App.swift", 27, 4, "Alas/Sources/App.swift"),
        ("@App.swift#run", 14, 0, "App.swift#run"), ("mail a@b", 8, nil, nil), ("@done next", 10, nil, nil),
        ("x\n@a", 4, 2, "a"),
    ] as [(String, Int, Int?, String?)])
    func mentionTokenIsTheAtWordAtTheCaret(text: String, caret: Int, start: Int?, query: String?) {
        let token = RemoteComposerText.activeMentionToken(in: text as NSString, caret: caret)
        #expect(token?.start == start)
        #expect(token?.query == query)
    }

    @Test(arguments: [
        ("/rev", 4, 0, "rev"), ("fix it /co", 10, 7, "co"), ("a/b", 3, nil, nil), ("/re view", 8, nil, nil),
    ] as [(String, Int, Int?, String?)])
    func slashTokenFindsTheCommandBeingTyped(text: String, caret: Int, start: Int?, query: String?) {
        let token = RemoteComposerText.slashToken(in: text as NSString, caret: caret)
        #expect(token?.start == start)
        #expect(token?.query == query)
    }

    @Test func filterSlashCommandsRanksExactThenPrefixThenContainsThenSubsequence() {
        let commands = ["/review", "/re", "/preview", "/rvw", "/re"].map { RemoteSlashCommand(command: $0) }
        #expect(RemoteComposerText.filterSlashCommands(commands, query: "re").map(\.command)
            == ["/re", "/review", "/preview"])
        #expect(RemoteComposerText.filterSlashCommands(commands, query: "").map(\.command)
            == ["/review", "/re", "/preview", "/rvw"])
    }

    @Test func moveTargetsNeverPassTheSendingHeadOrAScheduledItem() {
        func item(_ id: String, status: String = "pending", scheduled: Bool = false) -> RemoteQueuedPrompt {
            RemoteQueuedPrompt(id: id, text: "t", imageCount: 0, resourceCount: 0, status: status,
                               lastError: nil, scheduledAt: scheduled ? 1_800_000_000_000 : nil)
        }
        let targets = RemoteQueueRules.moveTargets([
            item("s", status: "sending"), item("a"), item("b"), item("c", scheduled: true),
        ])
        #expect(targets["a"] == .init(up: nil, down: "b"))
        #expect(targets["b"] == .init(up: "a", down: nil))
        #expect(targets["c"] == .init(up: nil, down: nil))
        #expect(targets["s"] == nil)
    }

    @Test(arguments: [
        (1, Array(repeating: 1, count: 9), nil),
        (1, Array(repeating: 1, count: 10), "Attachments are limited to 10 per prompt."),
        (10_000_000, [], nil),
        (10_000_001, [], "Attachments are limited to 10 MB per prompt."),
        (2, [9_999_999], "Attachments are limited to 10 MB per prompt."),
        (4_000_001, [6_000_000], "Attachments are limited to 10 MB per prompt."),
    ] as [(Int, [Int], String?)])
    func attachmentRefusalCapsCountAndTotalBytes(size: Int, staged: [Int], expected: String?) {
        #expect(RemoteAttachmentLimits.refusal(adding: size, to: staged) == expected)
    }
}
