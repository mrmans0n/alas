import Foundation
import Testing
@testable import Alas

@Suite("SnippetSession")
struct SnippetSessionTests {
    @Test func retainsChoiceAlternativesForSelectedStop() throws {
        let expansion = try SnippetSession.parse(#"${1|one,two\,three,four\|five|} ${2:end}$0"#)
        #expect(expansion.choices[1] == ["one", "two,three", "four|five"])
        var session = SnippetSession(expansion: expansion, offset: 0)
        #expect(session.currentChoices == ["one", "two,three", "four|five"])
        _ = session.advance(backwards: false)
        #expect(session.currentChoices.isEmpty)
    }

    @Test(arguments: ["$9223372036854775807 $UNKNOWN", "$2147483647 $UNKNOWN", "${9223372036854775807:x}", "$9223372036854775808", "${2147483648/(.*)/$1/}"])
    func oversizedStopIdentifiersFailClosed(source: String) {
        #expect(throws: (any Error).self) { try SnippetSession.parse(source) }
    }

    @Test func adjacentMirrorIsNotStructurallyInsideAnEmptyParent() throws {
        let expansion = try SnippetSession.parse("${1:$2}$2 $1$0")
        var session = SnippetSession(expansion: expansion, offset: 0)
        _ = session.advance(backwards: false)
        let planned = session.replacing(NSRange(location: 0, length: 0), with: "x")
        let plan = try #require(planned)
        let text = NSMutableString(string: expansion.text)
        for edit in plan.edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacementText) }
        #expect(text as String == "xx x")
        let parent = session.advance(backwards: true)
        #expect(parent == NSRange(location: 0, length: 1))
    }

    @Test func replacingParentKeepsCurrentStopAfterEarlierChildIsRemoved() throws {
        let expansion = try SnippetSession.parse("${2:${1:x}} ${3:y}$0")
        var session = SnippetSession(expansion: expansion, offset: 0)
        _ = session.advance(backwards: false)
        let planned = session.replacing(NSRange(location: 0, length: 1), with: "parent")
        let plan = try #require(planned)
        let text = NSMutableString(string: expansion.text)
        for edit in plan.edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacementText) }
        #expect(text as String == "parent y")
        #expect(plan.finalSelection == NSRange(location: 6, length: 0))
        #expect(session.selection == NSRange(location: 0, length: 6))
        let next = session.advance(backwards: false)
        #expect(next == NSRange(location: 7, length: 1))
        #expect(!session.isFinished)
    }

    @Test func editingForwardMirrorUpdatesItsNestedOccurrenceAndParent() throws {
        let expansion = try SnippetSession.parse("$2 ${1:foo ${2:bar}}$0")
        var session = SnippetSession(expansion: expansion, offset: 0)
        _ = session.advance(backwards: false)
        let planned = session.replacing(NSRange(location: 0, length: 3), with: "baz")
        let plan = try #require(planned)
        let text = NSMutableString(string: expansion.text)
        for edit in plan.edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacementText) }
        #expect(text as String == "baz foo baz")
        let parent = session.advance(backwards: true)
        #expect(parent == NSRange(location: 4, length: 7))
    }

    @Test(arguments: [
        (#"${1:ABC} ${1/(.*)/${1:/downcase}/}"#, "ABC abc"),
        (#"${1:foo_bar} ${1/(.*)/${1:/camelcase}/} ${1/(.*)/${1:/pascalcase}/}"#, "foo_bar fooBar FooBar"),
        (#"${1:a} ${1/(b)?/${1:?yes:no}/} ${1/(b)?/${1:-fallback}/}"#, "a noa fallbacka"),
        (#"${1:foo_foo} ${1/foo/bar/g}"#, "foo_foo bar_bar"),
        (#"${1:hi} ${1/(.*)/$1/}"#, "hi hi"),
        (#"${UNKNOWN} $1 ${1:ok}"#, "UNKNOWN ok ok"),
        (#"$1 ${1:${2:value}}"#, "value value"),
        (#"\$ \\ \} ${1|a\|b,c|}"#, "$ \\ } a|b")
    ])
    func standardSyntaxCorpus(source: String, expected: String) throws {
        #expect(try SnippetSession.parse(source).text == expected)
    }

    @Test func enforcesExpansionLimits() {
        #expect(throws: (any Error).self) { try SnippetSession.parse(String(repeating: "x", count: 65537)) }
        #expect(throws: (any Error).self) { try SnippetSession.parse(String(repeating: "${1:", count: 33) + String(repeating: "}", count: 33)) }
    }

    @Test func expandsNumberedPlaceholderAndFinalStop() throws {
        let expansion = try SnippetSession.parse("call(${1:value})$0")
        #expect(expansion.text == "call(value)")
        #expect(expansion.tabStops[1] == [NSRange(location: 5, length: 5)])
        #expect(expansion.finalCaret == 11)
    }

    @Test func nestedMirrorsChoicesEscapesAndUTF16() throws {
        let expansion = try SnippetSession.parse(#"😀${1:${2:foo}} $1 ${3|a\,b,c|} \$x$0"#)
        #expect(expansion.text == "😀foo foo a,b $x")
        #expect(expansion.tabStops[1] == [NSRange(location: 2, length: 3), NSRange(location: 6, length: 3)])
        #expect(expansion.tabStops[2] == [NSRange(location: 2, length: 3)])
        #expect(expansion.orderedStops == [1, 2, 3])
        #expect(expansion.finalCaret == 16)
    }

    @Test func variablesAndTransforms() throws {
        let expansion = try SnippetSession.parse(#"${TM_FILENAME/(.*)\..+$/${1:/upcase}/} ${MISSING:fallback} ${1:foo} ${1/(.*)/${1:+yes}-${1:/capitalize}/}"#,
                                                 variables: ["TM_FILENAME": "file.swift"])
        #expect(expansion.text == "FILE fallback foo yes-Foo")
    }

    @Test func forwardMirrorUsesLaterDefault() throws {
        #expect(try SnippetSession.parse("$1 ${1:value}").text == "value value")
    }

    @Test func nestedEditUpdatesContainingMirrorAndTransform() throws {
        var session = SnippetSession(expansion: try SnippetSession.parse("${1:foo ${2:bar}} = $1 ${2/(.*)/${1:/upcase}/}$0"), offset: 0)
        _ = session.advance(backwards: false)
        let planned = session.replacing(NSRange(location: 4, length: 3), with: "baz")
        let update = try #require(planned)
        let text = NSMutableString(string: "foo bar = foo bar BAR")
        for edit in update.edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacementText) }
        #expect(text as String == "foo baz = foo baz BAZ")
        let previous = session.advance(backwards: true)
        #expect(previous == NSRange(location: 0, length: 7))
    }

    @Test func unbracedStopAndUnknownVariable() throws {
        let expansion = try SnippetSession.parse("$1suffix ${UNKNOWN}")
        #expect(expansion.text == "suffix UNKNOWN")
        #expect(expansion.orderedStops.count == 2)
    }

    @Test(arguments: ["${1:broken", "${1|a,b}", "${1/[/x/}", "${1/a/${1:/unknown}/}"])
    func malformedSyntaxFailsWithoutInsertion(source: String) {
        #expect(throws: (any Error).self) { try SnippetSession.parse(source) }
    }

    @Test func navigationAndLinkedEdits() throws {
        var session = SnippetSession(expansion: try SnippetSession.parse("${1:foo}=$1 ${2:bar}$0"), offset: 2)
        #expect(session.selection == NSRange(location: 2, length: 3))
        let planned = session.replacing(NSRange(location: 2, length: 3), with: "😀")
        let update = try #require(planned)
        #expect(update.edits == [CompletionTextEdit(range: NSRange(location: 2, length: 3), replacementText: "😀"),
                                 CompletionTextEdit(range: NSRange(location: 6, length: 3), replacementText: "😀")])
        let second = session.advance(backwards: false)
        #expect(second == NSRange(location: 8, length: 3))
        let first = session.advance(backwards: true)
        #expect(first == NSRange(location: 2, length: 2))
        let again = session.advance(backwards: false)
        #expect(again == NSRange(location: 8, length: 3))
        let final = session.advance(backwards: false)
        #expect(final == NSRange(location: 11, length: 0))
        #expect(session.isFinished)
    }

    @Test func emptyMirrorsMoveFinalCaretAfterInsertedText() throws {
        var session = SnippetSession(expansion: try SnippetSession.parse("$1$1$2$0"), offset: 0)
        let update = session.replacing(NSRange(location: 0, length: 0), with: "x")
        #expect(update?.edits.count == 2)
        #expect(session.selection == NSRange(location: 0, length: 1))
        let second = session.advance(backwards: false)
        #expect(second == NSRange(location: 2, length: 0))
        let final = session.advance(backwards: false)
        #expect(final == NSRange(location: 2, length: 0))
    }

    @Test func adjacentEmptyStopsRetainSourceOrder() throws {
        var session = SnippetSession(expansion: try SnippetSession.parse("$2$1$0"), offset: 0)
        _ = session.replacing(NSRange(location: 0, length: 0), with: "x")
        let second = session.advance(backwards: false)
        #expect(second == NSRange(location: 0, length: 0))
        let next = session.replacing(NSRange(location: 0, length: 0), with: "y")
        #expect(next?.edits == [.init(range: NSRange(location: 0, length: 0), replacementText: "y")])
        let final = session.advance(backwards: false)
        #expect(final == NSRange(location: 2, length: 0))
    }

    @Test func nestedEmptyTransformKeepsContainingMirrorInSourceOrder() throws {
        var session = SnippetSession(expansion: try SnippetSession.parse("${1:$2${2/(.)/${1:/upcase}/}} $1$0"), offset: 0)
        _ = session.advance(backwards: false)
        let planned = session.replacing(NSRange(location: 0, length: 0), with: "x")
        let update = try #require(planned)
        let text = NSMutableString(string: " ")
        for edit in update.edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacementText) }
        #expect(text as String == "xX xX")
    }
}
