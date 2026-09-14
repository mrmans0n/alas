import AppKit
import Testing
@testable import Alas

struct SemanticTokensFeatureTests {
    @Test func appliesReadonlyModifierOnlyWhenPresent() throws {
        let spans = try SemanticTokensFeature.decode([0, 0, 1, 0, 0, 0, 1, 1, 0, 1], legend: ["variable"], text: "ab", modifiers: ["readonly"])
        #expect(spans == [.init(range: NSRange(location: 0, length: 1), capture: .variable), .init(range: NSRange(location: 1, length: 1), capture: .constant)])
    }

    @Test func rejectsOutOfRequestedRangeAndExcessiveTokenCounts() {
        #expect(throws: (any Error).self) {
            try SemanticTokensFeature.decode([0, 0, 1, 0, 0], legend: ["custom"], text: "ab", allowedRange: NSRange(location: 1, length: 1))
        }
        #expect(throws: (any Error).self) {
            try SemanticTokensFeature.decode(Array(repeating: 0, count: 1_000_005), legend: ["variable"], text: "a")
        }
    }

    @Test(arguments: [
        [0, 0, 2], [0, 0, 1, 1, 0], [0, 0, 0, 0, 0],
        [-1, 0, 1, 0, 0], [0, -1, 1, 0, 0], [1, 0, 1, 0, 0],
        [0, 1, 2, 0, 0], [0, 0, 1, 0, -1], [0, 0, 1, 0, 1],
        [0, 0, 2, 0, 0, 0, 1, 1, 0, 0], [Int.max, 0, 1, 0, 0]
    ])
    func rejectsMalformedTupleAtomically(_ data: [Int]) {
        #expect(throws: (any Error).self) {
            try SemanticTokensFeature.decode(data, legend: ["variable"], text: "ab")
        }
    }

    @Test func decodesRelativeUTF16PositionsAndRetainsUnknownSyntaxFallback() throws {
        let spans = try SemanticTokensFeature.decode(
            [0, 0, 2, 0, 0, 0, 3, 2, 1, 0, 1, 1, 2, 2, 0, 0, 3, 1, 3, 0],
            legend: ["string", "function", "class", "custom"], text: "😀 fn\r\n xx z"
        )
        #expect(spans == [
            HighlightSpan(range: NSRange(location: 0, length: 2), capture: .string),
            HighlightSpan(range: NSRange(location: 3, length: 2), capture: .function),
            HighlightSpan(range: NSRange(location: 8, length: 2), capture: .type)
        ])
    }

    @Test(arguments: [[0, 0, 3, 0, 0], [0, 1, 1, 0, 0], [0, 0, 1, 0, 0]])
    func rejectsMultilineAndSplitSurrogates(_ data: [Int]) {
        #expect(throws: (any Error).self) {
            try SemanticTokensFeature.decode(data, legend: ["variable"], text: "😀\nxy")
        }
    }

    @Test func rejectsMalformedSuffixAfterValidToken() {
        #expect(throws: (any Error).self) {
            try SemanticTokensFeature.decode([0, 0, 1, 0, 0, 0, 1, 5, 0, 0], legend: ["function"], text: "ab")
        }
    }
}

@MainActor
struct EditorSemanticLayerTests {
    @Test func rejectsOldServerAndMalformedReplacementWithoutRemovingCurrentColor() throws {
        let storage = NSTextStorage(string: "abc")
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let document = EditorDocumentID(host: nil, worktreeID: "w", uri: "file:///a")
        let range = LSPRange(start: .init(line: 0, character: 0), end: .init(line: 0, character: 3))
        let current = EditorRequestContext(document: document, version: 2, serverGeneration: UUID(), range: range)
        let oldServer = EditorRequestContext(document: document, version: 2, serverGeneration: UUID(), range: range)
        let oldVersion = EditorRequestContext(document: document, version: 1, serverGeneration: current.serverGeneration, range: range)
        let theme = EditorTheme(theme: try Theme.loadBundled(id: "cool-slate"))
        let layer = EditorSemanticLayer(layoutManager: layout, theme: theme, isCurrent: { $0 == current })
        let spans = [HighlightSpan(range: NSRange(location: 0, length: 3), capture: .function)]
        layer.replace(spans, context: current)
        let color = layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor
        for stale in [oldServer, oldVersion] { layer.replace([], context: stale) }
        layer.replace([.init(range: NSRange(location: 0, length: 3), capture: .type), .init(range: NSRange(location: 2, length: 5), capture: .keyword)], context: current)
        #expect(color != nil)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor == color)
        storage.replaceCharacters(in: NSRange(location: 0, length: 2), with: "")
        layer.clear()
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
    }

    @Test func temporaryForegroundComposesWithSyntaxDiagnosticsAndFind() throws {
        let storage = NSTextStorage(string: "abc")
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let context = EditorRequestContext(document: .init(host: nil, worktreeID: "w", uri: "file:///a"), version: 1,
                                           serverGeneration: UUID(), range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 3)))
        var current = true
        let theme = EditorTheme(theme: try Theme.loadBundled(id: "cool-slate"))
        let layer = EditorSemanticLayer(layoutManager: layout, theme: theme, isCurrent: { _ in current })
        let range = NSRange(location: 0, length: 3)
        storage.addAttributes([.foregroundColor: NSColor.red, .underlineStyle: 1], range: range)
        layout.addTemporaryAttribute(.backgroundColor, value: NSColor.yellow, forCharacterRange: range)
        layer.replace([.init(range: range, capture: .function)], context: context)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.red)
        storage.addAttribute(.foregroundColor, value: NSColor.blue, range: range)
        layer.reapply(theme: theme)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) != nil)
        current = false
        layer.replace([.init(range: range, capture: .type)], context: context)
        layer.reapply(theme: theme)
        #expect(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) == nil)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.blue)
        #expect(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == 1)
        #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor == NSColor.yellow)
    }
}
