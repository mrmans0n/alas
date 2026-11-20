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

    @Test func aDraftSendsItsChipsSpelledOutWithPastedSpansInUTF16() {
        let file = RemoteMention(kind: RemoteMention.file, value: "a/B.swift", name: "B.swift")
        let draft = RemoteComposerDraft(segments: [
            .chip(.command("/review")), .text(" 👍 "), .chip(.mention(file)), .text(" \r\n"),
            .chip(.pasted(ordinal: 1, text: "x\ny")), .text(" "), .chip(.reference(CodeHostReference(spelling: "#12")!)),
            .chip(.mention(file)),
        ])
        #expect(draft.text == "/review 👍 @B.swift \r\nx\ny #12@B.swift")
        #expect(draft.mentions == [file])
        #expect(draft.pastedSpans == [ACPPastedTextSpan(ordinal: 1, utf16Offset: 22, utf16Length: 3)])
        // A mention glued to the next chip gets a separating space.
        let glued = RemoteComposerDraft(segments: [.chip(.mention(file)), .chip(.pasted(ordinal: 2, text: "z"))])
        #expect(glued.text == "@B.swift z")
        #expect(glued.pastedSpans == [ACPPastedTextSpan(ordinal: 2, utf16Offset: 9, utf16Length: 1)])
    }

    @Test(arguments: [
        ("/review #12 done", 16, ["cmd:/review", "txt: ", "ref:#12", "txt: done"]),
        // The caret right after `#12`: its digits may still be coming.
        ("/review #12", 11, ["cmd:/review", "txt: #12"]),
        ("/review #12", nil, ["cmd:/review", "txt: ", "ref:#12"]),
        // Code stays text, and `!N` is not a reference on GitHub.
        ("`/review` !3 x", 14, ["txt:`/review` !3 x"]),
    ] as [(String, Int?, [String])])
    func restoringChipsCompletedTokensOutsideCode(text: String, caret: Int?, expected: [String]) {
        let draft = RemoteComposerDraft.restoring(text, commands: ["/review"], codeHost: .github, caret: caret)
        #expect(draft.segments.map(Self.describe) == expected)
        #expect(draft.text == text)
    }

    @Test func aLongPasteCollapsesAndARepositoryURLBecomesItsReference() {
        let repo = RemoteCodeHost(kind: .github, host: "github.com", webURL: URL(string: "https://github.com/o/r")!)
        let long = Array(repeating: "line", count: 21).joined(separator: "\n")
        #expect(RemoteComposerDraft.pasteSegments(long, replacing: NSRange(location: 0, length: 0), in: "",
                                                  commands: [], codeHost: repo, nextOrdinal: 3)
            == [.chip(.pasted(ordinal: 3, text: long))])
        #expect(RemoteComposerDraft.pasteSegments("https://github.com/o/r/pull/9 and /review now", replacing: NSRange(location: 4, length: 0),
                                                  in: "see ", commands: ["/review"], codeHost: repo, nextOrdinal: 1)
            .map(Self.describe) == ["ref:#9", "txt: and ", "cmd:/review", "txt: now"])
        #expect(RemoteComposerDraft.pasteSegments("#9", replacing: NSRange(location: 3, length: 0),
                                                  in: "abc", commands: [], codeHost: repo, nextOrdinal: 1)
            == [.text("#9")])
        // Inside code, a URL stays as pasted: between two backticks, or in a fenced block.
        let url = "https://github.com/o/r/pull/9"
        #expect(RemoteComposerDraft.pasteSegments(url, replacing: NSRange(location: 1, length: 0), in: "``",
                                                  commands: [], codeHost: repo, nextOrdinal: 1) == [.text(url)])
        #expect(RemoteComposerDraft.pasteSegments(url, replacing: NSRange(location: 4, length: 0), in: "```\n\n```",
                                                  commands: [], codeHost: repo, nextOrdinal: 1) == [.text(url)])
    }

    /// Editor offsets count a chip as one character; a replace splits text runs and keeps chips whole.
    @Test func aDraftEditsAndCopiesInDisplayUnits() {
        let file = RemoteMention(kind: RemoteMention.file, value: "B.swift", name: "B.swift")
        let draft = RemoteComposerDraft(segments: [.text("fix 👍 "), .chip(.mention(file)), .text(" now")])
        #expect(draft.displayText == "fix 👍 \u{FFFC} now")
        // "@B" typed after "now" becomes a mention: the token's range is replaced by the chip.
        let typed = draft.replacing(NSRange(location: 12, length: 0), with: [.text(" @B")])
        let picked = typed.replacing(NSRange(location: 13, length: 2), with: [.chip(.mention(file)), .text(" ")])
        #expect(picked.segments == [.text("fix 👍 "), .chip(.mention(file)), .text(" now "), .chip(.mention(file)), .text(" ")])
        // Deleting across a chip takes it whole.
        #expect(draft.replacing(NSRange(location: 4, length: 4), with: []).segments == [.text("fix  now")])
        #expect(draft.spelled(NSRange(location: 4, length: 5)) == "👍 @B.swift ")
    }

    private static func describe(_ segment: RemoteDraftSegment) -> String {
        switch segment {
        case .text(let text): "txt:" + text
        case .chip(.command(let command)): "cmd:" + command
        case .chip(.reference(let reference)): "ref:" + reference.spelling
        case .chip(.mention(let mention)): "men:" + mention.name
        case .chip(.pasted(let ordinal, _)): "pst:\(ordinal)"
        }
    }

    @Test(arguments: [
        ("", "one", "> one\n"),
        ("draft", "one\n\n**two**", "draft\n> one\n> \n> **two**\n"),
        ("draft\n", "one", "draft\n> one\n"),
    ])
    func quoteQuotesEveryLineOnItsOwnLinesAfterTheDraft(draft: String, message: String, expected: String) {
        #expect(ACPMessageQuote.appending(message, to: draft) == expected)
    }

    @Test func onlyNonWhitespaceMessagesCanBeQuoted() {
        #expect(ACPMessageQuote.canQuote("hello"))
        #expect(!ACPMessageQuote.canQuote(" \n\t"))
    }
}
