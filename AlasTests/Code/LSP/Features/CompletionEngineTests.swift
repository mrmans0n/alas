import Foundation
import Testing
@testable import Alas

@Suite("CompletionEngine")
struct CompletionEngineTests {
    @Test("detects identifier prefix before caret")
    func prefixBeforeCaret() {
        let text = "tabs.op"
        let prefix = CompletionEngine.prefix(in: text, caret: (text as NSString).length)
        #expect(prefix == CompletionPrefix(text: "op", range: NSRange(location: 5, length: 2)))
    }

    @Test("manual completion allows empty prefix")
    func emptyPrefixAtBoundary() {
        let prefix = CompletionEngine.prefix(in: "tabs.", caret: 5)
        #expect(prefix == CompletionPrefix(text: "", range: NSRange(location: 5, length: 0)))
    }

    @Test("extracts buffer-word fallback candidates")
    func bufferWordFallback() {
        let candidates = CompletionEngine.bufferWordCandidates(
            in: "openEditor openExternalEditor openedTabs openEditor",
            prefix: CompletionPrefix(text: "ope", range: NSRange(location: 0, length: 3))
        )
        #expect(candidates.map(\.label) == ["openEditor", "openExternalEditor", "openedTabs"])
        #expect(candidates.allSatisfy { $0.source == .buffer })
    }

    @Test("suppresses buffer-word fallback for short prefixes")
    func bufferWordFallbackRequiresSpecificPrefix() {
        let candidates = CompletionEngine.bufferWordCandidates(
            in: "openEditor openExternalEditor openedTabs",
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2))
        )

        #expect(candidates.isEmpty)
    }

    @Test("normalizes and ranks LSP items")
    func normalizeLSPItems() {
        let items = [
            LSPCompletionItem.testing(label: "openBeta", sortText: "002", filterText: "openBeta"),
            LSPCompletionItem.testing(label: "zebra", sortText: "003", filterText: nil),
            LSPCompletionItem.testing(label: "openAlpha", sortText: "001", filterText: "openAlpha")
        ]

        let candidates = CompletionEngine.lspCandidates(
            from: items,
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2))
        )

        #expect(candidates.map(\.label) == ["openAlpha", "openBeta"])
        #expect(candidates.allSatisfy { $0.source == .lsp })
    }

    @Test("filters LSP items by prefix instead of substring")
    func lspCandidatesRequirePrefixMatch() {
        let items = [
            LSPCompletionItem.testing(label: "openEditor", sortText: nil, filterText: "openEditor"),
            LSPCompletionItem.testing(label: "tabsOpenEditor", sortText: nil, filterText: "tabsOpenEditor")
        ]

        let candidates = CompletionEngine.lspCandidates(
            from: items,
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2))
        )

        #expect(candidates.map(\.label) == ["openEditor"])
    }

    @Test("trigger completions keep member-like LSP items")
    func triggerCompletionFiltersGlobalKinds() {
        let items = [
            LSPCompletionItem.testing(label: "count", kind: 10, sortText: nil, filterText: nil),
            LSPCompletionItem.testing(label: "append", kind: 2, sortText: nil, filterText: nil),
            LSPCompletionItem.testing(label: "String", kind: 7, sortText: nil, filterText: nil),
            LSPCompletionItem.testing(label: "if", kind: 14, sortText: nil, filterText: nil)
        ]

        let candidates = CompletionEngine.lspCandidates(
            from: items,
            prefix: CompletionPrefix(text: "", range: NSRange(location: 4, length: 0)),
            memberAccessOnly: true
        )

        #expect(candidates.map(\.label) == ["append", "count"])
    }

    @Test("matches longest completion trigger suffix before caret")
    func completionTriggerSuffix() {
        #expect(CompletionEngine.completionTriggerSuffix(
            in: "foo->",
            caret: 5,
            triggers: [">", "->", "."]
        ) == "->")
        #expect(CompletionEngine.completionTriggerSuffix(
            in: "Foo::",
            caret: 5,
            triggers: [":", "::", "."]
        ) == "::")
        #expect(CompletionEngine.completionTriggerSuffix(
            in: "foo.",
            caret: 4,
            triggers: ["->", "."]
        ) == ".")
    }

    @Test("uses textEdit newText before insertText")
    func textEditReplacementPrecedence() {
        let item = LSPCompletionItem.testing(
            label: "openEditor",
            sortText: nil,
            filterText: "openEditor",
            insertText: "insertTextValue",
            textEdit: LSPTextEdit(
                range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 2)),
                newText: "textEditValue"
            )
        )

        let candidates = CompletionEngine.lspCandidates(
            from: [item],
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2))
        )

        #expect(candidates.first?.replacementText == "textEditValue")
    }

    @Test("strips snippet placeholders to conservative plain text")
    func stripsSnippetPlaceholders() {
        #expect(CompletionEngine.plainText(fromSnippet: "openEditor(${1:path})$0") == "openEditor(path)")
        #expect(CompletionEngine.plainText(fromSnippet: "${1|public,private|} func ${2:name}()") == "public func name()")
        #expect(CompletionEngine.plainText(fromSnippet: "value${1}.${2}") == "value.")
    }

    @Test("plans primary prefix replacement")
    func plansPrimaryPrefixReplacement() {
        let candidate = CompletionCandidate(
            label: "openEditor",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openEditor",
            textEdit: nil,
            additionalTextEdits: [],
            source: .lsp
        )
        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 5, length: 2)),
            in: "tabs.op"
        )
        #expect(plan == CompletionEditPlan(edits: [
            CompletionTextEdit(range: NSRange(location: 5, length: 2), replacementText: "openEditor")
        ], finalSelection: NSRange(location: 15, length: 0)))
    }

    @Test("uses prefix replacement when LSP textEdit inserts full candidate at caret")
    func plansCaretInsertionTextEditAsPrefixReplacement() {
        let candidate = CompletionCandidate(
            label: "openEditor",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openEditor",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 7),
                    end: LSPPosition(line: 0, character: 7)
                ),
                newText: "openEditor"
            ),
            additionalTextEdits: [],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 5, length: 2)),
            in: "tabs.op"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 5, length: 2), replacementText: "openEditor")
        ])
        #expect(plan?.finalSelection == NSRange(location: 15, length: 0))
        #expect(plan.flatMap { apply($0, to: "tabs.op") } == "tabs.openEditor")
    }

    @Test("rebases an older LSP textEdit onto the current prefix")
    func plansStalePrefixTextEditAsCurrentPrefixReplacement() {
        let candidate = CompletionCandidate(
            label: "openAlpha",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openAlpha",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 4)
                ),
                newText: "openAlpha"
            ),
            additionalTextEdits: [],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "openA", range: NSRange(location: 0, length: 5)),
            in: "openA"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 0, length: 5), replacementText: "openAlpha")
        ])
        #expect(plan.flatMap { apply($0, to: "openA") } == "openAlpha")
    }

    @Test("shifts a retained textEdit that spans the old caret")
    func plansRetainedTextEditSpanningOldCaret() {
        let candidate = CompletionCandidate(
            label: "openAlpha",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openAlpha",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 6)
                ),
                newText: "openAlpha"
            ),
            additionalTextEdits: [],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "open", range: NSRange(location: 0, length: 4)),
            originalPrefix: CompletionPrefix(text: "ope", range: NSRange(location: 0, length: 3)),
            in: "openXYZ"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 0, length: 7), replacementText: "openAlpha")
        ])
        #expect(plan.flatMap { apply($0, to: "openXYZ") } == "openAlpha")
    }

    @Test("keeps a retained primary edit start before a grown prefix")
    func plansRetainedPrimaryEditStartingAtOldCaret() {
        let candidate = CompletionCandidate(
            label: "car",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "car",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 4),
                    end: LSPPosition(line: 0, character: 7)
                ),
                newText: "car"
            ),
            additionalTextEdits: [],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "c", range: NSRange(location: 4, length: 1)),
            originalPrefix: CompletionPrefix(text: "", range: NSRange(location: 4, length: 0)),
            in: "foo.cBar"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 4, length: 4), replacementText: "car")
        ])
        #expect(plan.flatMap { apply($0, to: "foo.cBar") } == "foo.car")
    }

    @Test("shifts a retained textEdit when the prefix shrinks")
    func plansRetainedTextEditAfterBackspace() {
        let candidate = CompletionCandidate(
            label: "openAlpha",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openAlpha",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 4)
                ),
                newText: "openAlpha"
            ),
            additionalTextEdits: [],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "ope", range: NSRange(location: 0, length: 3)),
            originalPrefix: CompletionPrefix(text: "open", range: NSRange(location: 0, length: 4)),
            in: "opeXYZ"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 0, length: 3), replacementText: "openAlpha")
        ])
        #expect(plan.flatMap { apply($0, to: "opeXYZ") } == "openAlphaXYZ")
    }

    @Test("clamps a retained textEdit inside a deleted prefix")
    func plansRetainedTextEditAfterMultipleBackspaces() {
        let candidate = CompletionCandidate(
            label: "openAlpha",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openAlpha",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 3),
                    end: LSPPosition(line: 0, character: 7)
                ),
                newText: "openAlpha"
            ),
            additionalTextEdits: [],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 0, length: 2)),
            originalPrefix: CompletionPrefix(text: "open", range: NSRange(location: 0, length: 4)),
            in: "opXYZ"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 2, length: 3), replacementText: "openAlpha")
        ])
        #expect(plan.flatMap { apply($0, to: "opXYZ") } == "opopenAlpha")
    }

    @Test("keeps an adjacent additional edit before a grown prefix")
    func plansAdjacentAdditionalEditAtOldCaret() {
        let candidate = CompletionCandidate(
            label: "count",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "count",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 4),
                    end: LSPPosition(line: 0, character: 4)
                ),
                newText: "count"
            ),
            additionalTextEdits: [
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 0, character: 0),
                        end: LSPPosition(line: 0, character: 4)
                    ),
                    newText: "object."
                )
            ],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "c", range: NSRange(location: 4, length: 1)),
            originalPrefix: CompletionPrefix(text: "", range: NSRange(location: 4, length: 0)),
            in: "foo.c"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 0, length: 4), replacementText: "object."),
            CompletionTextEdit(range: NSRange(location: 4, length: 1), replacementText: "count")
        ])
        #expect(plan.flatMap { apply($0, to: "foo.c") } == "object.count")
    }

    @Test("moves an adjacent additional edit with a shrinking prefix")
    func plansAdjacentAdditionalEditAfterBackspace() {
        let candidate = CompletionCandidate(
            label: "value",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "value",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 4),
                    end: LSPPosition(line: 0, character: 4)
                ),
                newText: "value"
            ),
            additionalTextEdits: [
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 0, character: 0),
                        end: LSPPosition(line: 0, character: 4)
                    ),
                    newText: "object."
                )
            ],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "ope", range: NSRange(location: 0, length: 3)),
            originalPrefix: CompletionPrefix(text: "open", range: NSRange(location: 0, length: 4)),
            in: "opeX"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 0, length: 3), replacementText: "object."),
            CompletionTextEdit(range: NSRange(location: 3, length: 0), replacementText: "value")
        ])
        #expect(plan.flatMap { apply($0, to: "opeX") } == "object.valueX")
    }

    @Test("moves a zero-length additional edit with a grown prefix")
    func plansAdditionalInsertionAtOldCaret() {
        let candidate = CompletionCandidate(
            label: "openAlpha",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openAlpha",
            textEdit: LSPTextEdit(
                range: LSPRange(
                    start: LSPPosition(line: 0, character: 0),
                    end: LSPPosition(line: 0, character: 3)
                ),
                newText: "openAlpha"
            ),
            additionalTextEdits: [
                LSPTextEdit(
                    range: LSPRange(
                        start: LSPPosition(line: 0, character: 3),
                        end: LSPPosition(line: 0, character: 3)
                    ),
                    newText: "!"
                )
            ],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "open", range: NSRange(location: 0, length: 4)),
            originalPrefix: CompletionPrefix(text: "ope", range: NSRange(location: 0, length: 3)),
            in: "open"
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 0, length: 4), replacementText: "openAlpha"),
            CompletionTextEdit(range: NSRange(location: 4, length: 0), replacementText: "!")
        ])
        #expect(plan.flatMap { apply($0, to: "open") } == "openAlpha!")
    }

    @Test("plans textEdit plus non-overlapping additional edits")
    func plansAdditionalTextEdits() {
        let text = "let value = op\n"
        let primary = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 12), end: LSPPosition(line: 0, character: 14)),
            newText: "openEditor"
        )
        let importEdit = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
            newText: "import Foundation\n"
        )
        let candidate = CompletionCandidate(
            label: "openEditor",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openEditor",
            textEdit: primary,
            additionalTextEdits: [importEdit],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 12, length: 2)),
            in: text
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 0, length: 0), replacementText: "import Foundation\n"),
            CompletionTextEdit(range: NSRange(location: 12, length: 2), replacementText: "openEditor")
        ])
        #expect(plan?.finalSelection == NSRange(location: 40, length: 0))
        #expect(plan.flatMap { apply($0, to: text) } == "import Foundation\nlet value = openEditor\n")
    }

    @Test("plans LSP textEdit after UTF-16 surrogate pair")
    func plansTextEditAfterSurrogatePair() {
        let text = "let icon = \"😀\"\nlet value = op\n"
        let primary = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 1, character: 12), end: LSPPosition(line: 1, character: 14)),
            newText: "openEditor"
        )
        let candidate = CompletionCandidate(
            label: "openEditor",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openEditor",
            textEdit: primary,
            additionalTextEdits: [],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 28, length: 2)),
            in: text
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 28, length: 2), replacementText: "openEditor")
        ])
        #expect(plan?.finalSelection == NSRange(location: 38, length: 0))
        #expect(plan.flatMap { apply($0, to: text) } == "let icon = \"😀\"\nlet value = openEditor\n")
    }

    @Test("rejects overlapping additional edits")
    func rejectsOverlappingAdditionalEdits() {
        let text = "let value = op\n"
        let primary = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 12), end: LSPPosition(line: 0, character: 14)),
            newText: "openEditor"
        )
        let overlap = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 13), end: LSPPosition(line: 0, character: 14)),
            newText: "x"
        )
        let candidate = CompletionCandidate(
            label: "openEditor",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "openEditor",
            textEdit: primary,
            additionalTextEdits: [overlap],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "op", range: NSRange(location: 12, length: 2)),
            in: text
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 12, length: 2), replacementText: "openEditor")
        ])
    }

    @Test("rejects same-position insertion additional edits")
    func rejectsSamePositionInsertionAdditionalEdits() {
        let text = ""
        let primary = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
            newText: "primary"
        )
        let samePositionInsert = LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 0)),
            newText: "additional"
        )
        let candidate = CompletionCandidate(
            label: "primary",
            detail: nil,
            kind: nil,
            documentation: nil,
            sortText: nil,
            filterText: nil,
            replacementText: "primary",
            textEdit: primary,
            additionalTextEdits: [samePositionInsert],
            source: .lsp
        )

        let plan = CompletionEngine.editPlan(
            accepting: candidate,
            prefix: CompletionPrefix(text: "", range: NSRange(location: 0, length: 0)),
            in: text
        )

        #expect(plan?.edits == [
            CompletionTextEdit(range: NSRange(location: 0, length: 0), replacementText: "primary")
        ])
    }
}

private func apply(_ plan: CompletionEditPlan, to text: String) -> String? {
    let storage = NSMutableString(string: text)
    for edit in plan.edits.reversed() {
        guard edit.range.location >= 0,
              edit.range.length >= 0,
              NSMaxRange(edit.range) <= storage.length else {
            return nil
        }
        storage.replaceCharacters(in: edit.range, with: edit.replacementText)
    }
    return storage as String
}

extension LSPCompletionItem {
    static func testing(
        label: String,
        kind: Int? = nil,
        sortText: String?,
        filterText: String?,
        insertText: String? = nil,
        insertTextFormat: LSPInsertTextFormat? = nil,
        textEdit: LSPTextEdit? = nil
    ) -> LSPCompletionItem {
        LSPCompletionItem(
            label: label,
            kind: kind,
            detail: nil,
            documentation: nil,
            sortText: sortText,
            filterText: filterText,
            insertText: insertText,
            insertTextFormat: insertTextFormat,
            textEdit: textEdit,
            additionalTextEdits: nil
        )
    }
}
