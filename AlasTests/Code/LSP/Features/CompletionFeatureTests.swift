import AppKit
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct CompletionFeatureTests {
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

    @Test("trigger completion flushes pending document changes before request")
    func triggerCompletionFlushesBeforeRequest() async throws {
        let transport = FakeTransport()
        let client = LSPClient(transport: transport, language: "swift", rootURI: "file:///tmp")
        var events: [String] = []
        var completionRequest = ""
        transport.onSend = { sent in
            if sent.contains(#""method":"initialize""#) {
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"completionProvider":{"triggerCharacters":["."]}}}}"#)
            } else if sent.contains(#""method":"textDocument/completion""#) {
                events.append("completion")
                completionRequest = sent
                transport.deliverFrame(#"{"jsonrpc":"2.0","id":2,"result":{"isIncomplete":false,"items":[]}}"#)
            }
        }
        try await client.initialize()

        let textView = makeTextView("foo.")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { client },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true },
            prepareForCompletionRequest: {
                events.append("flush")
            }
        )

        textView.completionChangeHandler?()
        try await waitForCompletionRequest(events: { events })

        #expect(events == ["flush", "completion"])
        #expect(completionRequest.contains(#""triggerKind":2"#))
        #expect(completionRequest.contains(#""triggerCharacter":".""#))
        feature.cancelAndDismiss()
        transport.finish()
    }

    @Test("member-only filtering is limited to member access triggers")
    func memberOnlyFilteringTriggerCharacters() {
        #expect(CompletionFeature.isMemberAccessTriggerCharacter("."))
        #expect(CompletionFeature.isMemberAccessTriggerCharacter("->"))
        #expect(CompletionFeature.isMemberAccessTriggerCharacter("::"))
        #expect(!CompletionFeature.isMemberAccessTriggerCharacter("/"))
        #expect(!CompletionFeature.isMemberAccessTriggerCharacter("\""))
        #expect(!CompletionFeature.isMemberAccessTriggerCharacter(nil))
    }

    @Test("refresh keeps matching candidates while awaiting the next response")
    func refreshKeepsMatchingCandidatesWhileAwaitingNextResponse() {
        let textView = makeTextView("open")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingSeedVisibleCandidates(
            labels: ["openAlpha", "openBeta"],
            prefix: CompletionPrefix(text: "open", range: NSRange(location: 0, length: 4))
        )
        feature.testingShowPopup()

        textView.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha"])
        #expect(feature.testingSnapshot.prefix == CompletionPrefix(text: "openA", range: NSRange(location: 0, length: 5)))
        #expect(feature.testingSnapshot.selection == 0)
        #expect(!feature.testingSnapshot.isRefreshing)

        textView.deleteBackward(nil)

        #expect(textView.string == "open")
        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha", "openBeta"])

        textView.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(feature.testingSnapshot.candidateLabels.isEmpty)
        #expect(feature.testingSnapshot.prefix == CompletionPrefix(text: "openZ", range: NSRange(location: 0, length: 5)))

        textView.deleteBackward(nil)

        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha", "openBeta"])

        textView.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(textView.completionKeyHandler?(.acceptTop) == true)
        #expect(textView.string == "openAlpha")
        feature.cancelAndDismiss()
    }

    @Test("refresh discards candidates when text changes outside the prefix")
    func refreshDiscardsCandidatesAfterForwardDelete() {
        let textView = makeTextView("opeXYZ tail")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingSeedVisibleCandidates(
            labels: ["openAlpha"],
            prefix: CompletionPrefix(text: "ope", range: NSRange(location: 0, length: 3))
        )

        textView.deleteForward(nil)

        #expect(textView.string == "opeYZ tail")
        #expect(feature.testingSnapshot.candidateLabels.isEmpty)
        #expect(feature.testingSnapshot.prefix == nil)
        feature.cancelAndDismiss()
    }

    @Test("refresh preserves the selected matching candidate")
    func refreshPreservesSelectedMatchingCandidate() {
        let textView = makeTextView("a")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingSeedVisibleCandidates(
            labels: ["alpha", "apple", "apricot"],
            prefix: CompletionPrefix(text: "a", range: NSRange(location: 0, length: 1)),
            selection: 1
        )

        textView.insertText("p", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(feature.testingSnapshot.candidateLabels == ["apple", "apricot"])
        #expect(feature.testingSnapshot.selection == 0)
        feature.cancelAndDismiss()
    }

    @Test("refreshed results preserve the selected candidate")
    func refreshedResultsPreserveSelectedCandidate() {
        let textView = makeTextView("apTail")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        let prefix = CompletionPrefix(text: "ap", range: NSRange(location: 0, length: 2))
        feature.testingPresent(
            items: [
                completionItem(label: "append", sortText: "001", replacement: "append", rangeEnd: 6),
                completionItem(label: "append", sortText: "002", replacement: "append", rangeEnd: 2)
            ],
            prefix: prefix,
            bufferText: "apTail"
        )
        feature.testingSetSelection(0)

        feature.testingPresent(
            items: [
                completionItem(label: "append", sortText: "001", replacement: "append", rangeEnd: 2),
                completionItem(label: "append", sortText: "002", replacement: "append", rangeEnd: 6)
            ],
            prefix: prefix,
            bufferText: "apTail"
        )

        #expect(feature.testingSnapshot.candidateLabels == ["append", "append"])
        #expect(feature.testingSnapshot.selection == 1)
        #expect(textView.completionKeyHandler?(.acceptSelected) == true)
        #expect(textView.string == "append")
        feature.cancelAndDismiss()
    }

    private func completionItem(
        label: String,
        sortText: String,
        replacement: String,
        rangeEnd: Int
    ) -> LSPCompletionItem {
        .testing(
            label: label,
            sortText: sortText,
            filterText: nil,
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: rangeEnd)
                ),
                newText: replacement
            )
        )
    }

    private func waitForCompletionRequest(events: () -> [String]) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !events().contains("completion"), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
