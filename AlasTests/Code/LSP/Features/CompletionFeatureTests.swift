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

        textView.completionChangeHandler?(nil)
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

    @Test("refresh retains candidates from a broader response")
    func refreshRetainsBroaderResponse() {
        func item(_ label: String, sortText: String, rangeLength: Int) -> LSPCompletionItem {
            .testing(
                label: label,
                sortText: sortText,
                filterText: nil,
                textEdit: LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 0, character: 0),
                        end: LSPPosition(line: 0, character: rangeLength)
                    ),
                    newText: label
                )
            )
        }

        let textView = makeTextView("o")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingPresent(
            items: [
                item("openAlpha", sortText: "001", rangeLength: 1),
                item("operate", sortText: "002", rangeLength: 1),
                item("output", sortText: "003", rangeLength: 1)
            ],
            prefix: CompletionPrefix(text: "o", range: NSRange(location: 0, length: 1)),
            bufferText: "o"
        )

        textView.insertText("p", replacementRange: NSRange(location: NSNotFound, length: 0))
        feature.testingPresent(
            items: [
                item("openAlpha", sortText: "001", rangeLength: 2),
                item("operate", sortText: "002", rangeLength: 2)
            ],
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2)),
            bufferText: "op"
        )
        feature.testingSetSelection(1)
        textView.deleteBackward(nil)

        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha", "operate", "output"])
        #expect(feature.testingSnapshot.selection == 1)
        feature.cancelAndDismiss()
    }

    @Test("refresh restores broader candidates at an intermediate prefix")
    func refreshRestoresBroaderResponseImmediately() {
        let textView = makeTextView("o")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingPresent(
            items: [
                .testing(label: "openAlpha", sortText: "001", filterText: nil),
                .testing(label: "operate", sortText: "002", filterText: nil),
                .testing(label: "opaque", sortText: "003", filterText: nil)
            ],
            prefix: CompletionPrefix(text: "o", range: NSRange(location: 0, length: 1)),
            bufferText: "o"
        )

        textView.insertText("pen", replacementRange: NSRange(location: NSNotFound, length: 0))
        feature.testingPresent(
            items: [.testing(label: "openAlpha", sortText: "001", filterText: nil)],
            prefix: CompletionPrefix(text: "open", range: NSRange(location: 0, length: 4)),
            bufferText: "open"
        )
        textView.deleteBackward(nil)

        #expect(textView.string == "ope")
        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha", "operate"])

        textView.deleteBackward(nil)

        #expect(textView.string == "op")
        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha", "operate", "opaque"])
        feature.cancelAndDismiss()
    }

    @Test("refresh retains matching candidates introduced by a narrow response")
    func refreshRetainsNarrowResponseCandidates() {
        let textView = makeTextView("o")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingPresent(
            items: [.testing(label: "openAlpha", sortText: "001", filterText: nil)],
            prefix: CompletionPrefix(text: "o", range: NSRange(location: 0, length: 1)),
            bufferText: "o"
        )

        textView.insertText("p", replacementRange: NSRange(location: NSNotFound, length: 0))
        feature.testingPresent(
            items: [
                .testing(label: "openAlpha", sortText: "001", filterText: nil),
                .testing(label: "operate", sortText: "002", filterText: nil)
            ],
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2)),
            bufferText: "op"
        )
        feature.testingSetSelection(1)
        textView.deleteBackward(nil)

        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha", "operate"])
        #expect(feature.testingSnapshot.selection == 1)
        feature.cancelAndDismiss()
    }

    @Test("refresh retains candidates introduced by an intermediate response")
    func refreshRetainsIntermediateResponseCandidates() {
        let textView = makeTextView("o")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingPresent(
            items: [.testing(label: "openAlpha", sortText: "001", filterText: nil)],
            prefix: CompletionPrefix(text: "o", range: NSRange(location: 0, length: 1)),
            bufferText: "o"
        )

        textView.insertText("p", replacementRange: NSRange(location: NSNotFound, length: 0))
        feature.testingPresent(
            items: [
                .testing(label: "openAlpha", sortText: "001", filterText: nil),
                .testing(label: "option", sortText: "002", filterText: nil)
            ],
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2)),
            bufferText: "op"
        )

        textView.insertText("e", replacementRange: NSRange(location: NSNotFound, length: 0))
        feature.testingPresent(
            items: [.testing(label: "openAlpha", sortText: "001", filterText: nil)],
            prefix: CompletionPrefix(text: "ope", range: NSRange(location: 0, length: 3)),
            bufferText: "ope"
        )
        textView.deleteBackward(nil)

        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha", "option"])
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

    @Test("refresh restores candidates at an empty trigger prefix")
    func refreshRestoresCandidatesAtEmptyPrefix() {
        let textView = makeTextView("foo.")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingPresent(
            items: [
                .testing(label: "count", kind: 10, sortText: "001", filterText: nil),
                .testing(label: "copy", kind: 2, sortText: "002", filterText: nil)
            ],
            prefix: CompletionPrefix(text: "", range: NSRange(location: 4, length: 0)),
            bufferText: "foo.",
            allowEmptyPrefix: true,
            memberAccessOnly: true
        )

        textView.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
        feature.testingPresent(
            items: [
                .testing(label: "count", kind: 10, sortText: "001", filterText: nil),
                .testing(label: "copy", kind: 2, sortText: "002", filterText: nil),
                .testing(label: "case", kind: 14, sortText: "003", filterText: nil)
            ],
            prefix: CompletionPrefix(text: "c", range: NSRange(location: 4, length: 1)),
            bufferText: "foo.c"
        )

        #expect(feature.testingSnapshot.candidateLabels == ["count", "copy"])
        textView.deleteBackward(nil)

        #expect(textView.string == "foo.")
        #expect(feature.testingSnapshot.candidateLabels == ["count", "copy"])
        feature.cancelAndDismiss()
    }

    @Test("automatic refresh dismisses at an empty prefix")
    func automaticRefreshDismissesAtEmptyPrefix() {
        let textView = makeTextView("o")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingSeedVisibleCandidates(
            labels: ["openAlpha"],
            prefix: CompletionPrefix(text: "o", range: NSRange(location: 0, length: 1))
        )

        textView.deleteBackward(nil)

        #expect(textView.string.isEmpty)
        #expect(feature.testingSnapshot.candidateLabels.isEmpty)
        #expect(feature.testingSnapshot.prefix == nil)
        feature.cancelAndDismiss()
    }

    @Test("refresh rebuilds candidates when broadening past the response prefix")
    func refreshRebuildsCandidatesPastResponsePrefix() {
        let textView = makeTextView("open")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingPresent(
            items: [
                .testing(label: "openAlpha", sortText: "001", filterText: nil),
                .testing(label: "operate", sortText: "002", filterText: nil)
            ],
            prefix: CompletionPrefix(text: "open", range: NSRange(location: 0, length: 4)),
            bufferText: "open"
        )

        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha"])

        textView.deleteBackward(nil)

        #expect(textView.string == "ope")
        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha", "operate"])
        feature.cancelAndDismiss()
    }

    @Test("refresh filters cached buffer words when broadening the prefix")
    func refreshFiltersCachedBufferWords() {
        let text = "openEditor operate\nopen"
        let textView = makeTextView(text)
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        let prefix = CompletionEngine.prefix(in: text, caret: (text as NSString).length)!
        feature.testingPresent(
            items: [],
            prefix: prefix,
            bufferText: text,
            allowBufferFallback: true
        )

        #expect(feature.testingSnapshot.candidateLabels == ["openEditor"])

        textView.deleteBackward(nil)

        #expect(feature.testingSnapshot.candidateLabels == ["openEditor", "operate", "open"])

        textView.deleteBackward(nil)

        #expect(feature.testingSnapshot.candidateLabels.isEmpty)
        feature.cancelAndDismiss()
    }

    @Test("empty refresh response retains candidates for backspacing")
    func emptyRefreshRetainsCandidates() {
        let textView = makeTextView("op")
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        feature.testingPresent(
            items: [.testing(label: "openAlpha", sortText: "001", filterText: nil)],
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2)),
            bufferText: "op"
        )

        textView.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        feature.testingPresent(
            items: [],
            prefix: CompletionPrefix(text: "opZ", range: NSRange(location: 0, length: 3)),
            bufferText: "opZ"
        )
        #expect(feature.testingSnapshot.candidateLabels.isEmpty)

        textView.deleteBackward(nil)

        #expect(feature.testingSnapshot.candidateLabels == ["openAlpha"])
        feature.cancelAndDismiss()
    }

    @Test("narrow responses extend the retained buffer cache")
    func narrowResponseExtendsBufferCache() {
        let text = "operate openEditor\no"
        let textView = makeTextView(text)
        let feature = CompletionFeature(
            textView: textView,
            getClient: { nil },
            getURI: { "file:///tmp/foo.swift" },
            isEnabled: { true }
        )
        let item = LSPCompletionItem.testing(label: "openAlpha", sortText: "001", filterText: nil)
        feature.testingPresent(
            items: [item],
            prefix: CompletionEngine.prefix(in: text, caret: (text as NSString).length)!,
            bufferText: text,
            allowBufferFallback: true
        )

        textView.insertText("pen", replacementRange: NSRange(location: NSNotFound, length: 0))
        feature.testingPresent(
            items: [item],
            prefix: CompletionEngine.prefix(in: textView.string, caret: textView.selectedRange().location)!,
            bufferText: textView.string,
            allowBufferFallback: true
        )
        textView.deleteBackward(nil)

        #expect(feature.testingSnapshot.candidateLabels.contains("operate"))
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
