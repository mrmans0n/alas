import AppKit
import Foundation
import Markdown
import Testing
@testable import Alas

@Suite("Diagnostic details")
struct DiagnosticDetailsTests {
    @Test("preserves diagnostic metadata and opaque data on the wire")
    func preservesDiagnosticMetadata() throws {
        let raw = Data(#"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"Unknown name","severity":1,"source":"ts","code":2304,"codeDescription":{"href":"https://example.test/2304"},"tags":[1,2],"relatedInformation":[{"location":{"uri":"ssh://build.example/work/main.ts","range":{"start":{"line":8,"character":2},"end":{"line":8,"character":5}}},"message":"Declared remotely"}],"data":{"token":90071992547409931234567890,"null":null}}"#.utf8)

        let diagnostic = try #require(LSPDiagnostic.decodeWire([LSPJSONValue.decode(from: raw)]).first)

        #expect(diagnostic.source == "ts")
        #expect(diagnostic.code == .number("2304"))
        #expect(diagnostic.codeDescription?.href == "https://example.test/2304")
        #expect(diagnostic.tags == [1, 2])
        #expect(diagnostic.relatedInformation?.first?.location.uri == "ssh://build.example/work/main.ts")
        #expect(diagnostic.relatedInformation?.first?.location.range.start == LSPPosition(line: 8, character: 2))
        #expect(diagnostic.data == .object(["token": .number("90071992547409931234567890"), "null": .null]))
        #expect(try diagnostic.wireValue?.encodedData().contains(Data("90071992547409931234567890".utf8)) == true)
    }

    @Test("preserves string diagnostic codes")
    func preservesStringDiagnosticCode() throws {
        let diagnostic = try JSONDecoder().decode(LSPDiagnostic.self, from: Data(#"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"message":"m","code":"unused"}"#.utf8))

        #expect(diagnostic.code == .string("unused"))
    }

    @Test("keeps extreme numeric codes and data from the diagnostic wire value")
    func keepsExtremeNumericMetadata() throws {
        let raw = Data(#"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"m","code":1e1000,"data":{"exponent":1e1000,"integer":123456789012345678901234567890123456789012345678901234567890}}"#.utf8)

        let diagnostic = try #require(LSPDiagnostic.decodeWire([LSPJSONValue.decode(from: raw)]).first)

        #expect(diagnostic.code == .number("1e1000"))
        #expect(diagnostic.data == .object([
            "exponent": .number("1e1000"),
            "integer": .number("123456789012345678901234567890123456789012345678901234567890")
        ]))
    }

    @Test @MainActor func replacesPushAndPullBatchesWhileRetainingZeroWidthDiagnostics() {
        let feature = DiagnosticsFeature()
        let storage = NSTextStorage(string: "abc")
        let push = diagnostic(message: "push", severity: 2, start: 1, end: 1)
        let pull = diagnostic(message: "pull", severity: 1, start: 2, end: 3)

        feature.apply([push], to: storage, theme: .fallback)
        #expect(feature.current.map(\.message) == ["push"])
        #expect(DiagnosticsFeature.nsRange(for: push.range, in: storage.string) == NSRange(location: 1, length: 0))

        feature.apply([pull], to: storage, theme: .fallback)
        #expect(feature.current.map(\.message) == ["pull"])
    }

    @Test @MainActor func invalidDisplayRangesDoNotChangeTheWireRange() {
        let feature = DiagnosticsFeature()
        let storage = NSTextStorage(string: "abc")
        let original = diagnostic(message: "out of date", severity: 1, start: 1, end: 99)

        feature.apply([original], to: storage, theme: .fallback)

        #expect(DiagnosticsFeature.nsRange(for: original.range, in: storage.string) == nil)
        #expect(feature.current.first?.range == original.range)
    }

    @Test @MainActor func ordersEqualLocationDetailsBySeverity() {
        let feature = DiagnosticsFeature()
        let storage = NSTextStorage(string: "abc")

        feature.apply([
            diagnostic(message: "hint", severity: 4, start: 1, end: 2),
            diagnostic(message: "error", severity: 1, start: 1, end: 2),
            diagnostic(message: "warning", severity: 2, start: 1, end: 2)
        ], to: storage, theme: .fallback)

        #expect(feature.diagnostics(at: LSPPosition(line: 0, character: 1)).map(\.message) == ["error", "warning", "hint"])
    }

    @Test @MainActor func nextAndPreviousProblemsUsePrimaryCaretAndWrap() {
        let feature = DiagnosticsFeature()
        let storage = NSTextStorage(string: "abcdef")
        let first = diagnostic(message: "first", severity: 2, start: 1, end: 2)
        let last = diagnostic(message: "last", severity: 1, start: 4, end: 5)
        feature.apply([last, first], to: storage, theme: .fallback)

        #expect(feature.nextRange(after: LSPPosition(line: 0, character: 2), backwards: false) == last.range)
        #expect(feature.nextRange(after: LSPPosition(line: 0, character: 5), backwards: false) == first.range)
        #expect(feature.nextRange(after: LSPPosition(line: 0, character: 4), backwards: true) == first.range)
        #expect(feature.nextRange(after: LSPPosition(line: 0, character: 0), backwards: true) == last.range)
    }

    @Test @MainActor func previousProblemUsesStartsForAdjacentAndOverlappingRanges() {
        let feature = DiagnosticsFeature()
        let storage = NSTextStorage(string: "abcdef")
        let left = diagnostic(message: "left", severity: 1, start: 1, end: 2)
        let right = diagnostic(message: "right", severity: 1, start: 2, end: 3)
        let overlapping = diagnostic(message: "overlap", severity: 1, start: 1, end: 4)
        let nested = diagnostic(message: "nested", severity: 1, start: 2, end: 5)

        feature.apply([right, left], to: storage, theme: .fallback)
        #expect(feature.nextRange(after: LSPPosition(line: 0, character: 2), backwards: true) == left.range)

        feature.apply([nested, overlapping], to: storage, theme: .fallback)
        #expect(feature.nextRange(after: LSPPosition(line: 0, character: 2), backwards: true) == overlapping.range)
        #expect(feature.nextRange(after: LSPPosition(line: 0, character: 4), backwards: true) == nested.range)
    }

    @Test func detailMarkdownIncludesMetadataAndRelatedLinks() throws {
        let diagnostic = try #require(LSPDiagnostic.decodeWire([LSPJSONValue.decode(from: Data(#"{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"Unknown name","severity":1,"source":"ts","code":2304,"codeDescription":{"href":"https://example.test/2304"},"relatedInformation":[{"location":{"uri":"file:///tmp/related.ts","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}}},"message":"Declared here"}]}"#.utf8))]).first)

        let markdown = DiagnosticsFeature.detailMarkdown(for: diagnostic)

        #expect(markdown.contains("Error"))
        #expect(markdown.contains("ts 2304"))
        #expect(markdown.contains("https://example.test/2304"))
        #expect(markdown.contains("Unknown name"))
        #expect(markdown.contains("alas-diagnostic://related/0"))
        #expect(markdown.contains("alas-diagnostic://actions"))
    }

    @Test @MainActor func detailRenderingPreservesLiteralDiagnosticAndRelatedMessages() throws {
        let message = "Generic <T> [not a link](nope) *literal*"
        let related = "Related [label] <U>"
        let diagnostic = try #require(LSPDiagnostic.decodeWire([LSPJSONValue.decode(from: Data("""
        {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"message":"\(message)","relatedInformation":[{"location":{"uri":"file:///tmp/related.ts","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}}},"message":"\(related)"}]}
        """.utf8))]).first)

        let result = MarkdownRenderer().render(
            document: Document(parsing: DiagnosticsFeature.detailMarkdown(for: diagnostic)),
            theme: try Theme.loadBundled(id: "cool-slate"),
            monospacedFontFamily: "SF Mono",
            monospacedFontSize: 13,
            baseDirectory: URL(fileURLWithPath: "/")
        )

        #expect(result.attributedString.string.contains(message))
        #expect(result.attributedString.string.contains(related))
        let relatedRange = (result.attributedString.string as NSString).range(of: related)
        #expect(result.attributedString.attribute(.link, at: relatedRange.location, effectiveRange: nil) != nil)
    }

    private func diagnostic(message: String, severity: Int, start: Int, end: Int) -> LSPDiagnostic {
        try! JSONDecoder().decode(LSPDiagnostic.self, from: Data("""
        {"range":{"start":{"line":0,"character":\(start)},"end":{"line":0,"character":\(end)}},"message":"\(message)","severity":\(severity)}
        """.utf8))
    }
}
