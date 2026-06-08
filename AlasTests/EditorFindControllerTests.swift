// AlasTests/EditorFindControllerTests.swift
import Testing
import AppKit
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorFindControllerTests {
    private func makeTextView(_ text: String = "") -> CodeTextView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 800, height: 600))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let textView = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return textView
    }

    @Test func replaceCurrentUpdatesText() {
        let textView = makeTextView("hello world")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "world"
        controller.replacementString = "universe"

        let didReplace = controller.replaceCurrent()

        #expect(didReplace == true)
        #expect(textView.string == "hello universe")
    }

    @Test func replaceCurrentMovesToNextMatch() {
        let textView = makeTextView("cat cat cat")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "cat"
        controller.replacementString = "dog"

        let first = controller.replaceCurrent()
        #expect(first == true)
        #expect(textView.string == "dog cat cat")

        let second = controller.replaceCurrent()
        #expect(second == true)
        #expect(textView.string == "dog dog cat")
    }

    @Test func replaceAllReplacesRepeatedMatches() {
        let textView = makeTextView("a b a b a")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "a"
        controller.replacementString = "x"

        let count = controller.replaceAll()

        #expect(count == 3)
        #expect(textView.string == "x b x b x")
    }

    @Test func replaceAllReturnsZeroForNoMatches() {
        let textView = makeTextView("hello world")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "xyz"
        controller.replacementString = "abc"

        let count = controller.replaceAll()

        #expect(count == 0)
        #expect(textView.string == "hello world")
    }

    @Test func emptyReplacementDeletesMatches() {
        let textView = makeTextView("abcXYZabc")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "XYZ"
        controller.replacementString = ""

        let count = controller.replaceAll()

        #expect(count == 1)
        #expect(textView.string == "abcabc")
    }

    @Test func emptyFindTextPerformsNoMutation() {
        let textView = makeTextView("hello world")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = ""
        controller.replacementString = "x"

        let didReplace = controller.replaceCurrent()
        let count = controller.replaceAll()

        #expect(didReplace == false)
        #expect(count == 0)
        #expect(textView.string == "hello world")
    }

    @Test func replaceCurrentWithSelectedMatch() {
        let textView = makeTextView("foo bar baz")
        textView.setSelectedRange(NSRange(location: 4, length: 3)) // select "bar"
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "bar"
        controller.replacementString = "qux"

        let didReplace = controller.replaceCurrent()

        #expect(didReplace == true)
        #expect(textView.string == "foo qux baz")
    }

    @Test func countMatchesReportsThree() {
        let textView = makeTextView("one two one two one")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "one"

        let count = controller.countMatches()

        #expect(count == 3)
        #expect(controller.matchCount == 3)
    }

    @Test func defaultSearchIsCaseInsensitive() {
        let textView = makeTextView("Cat cat CAT catalog")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "cat"

        controller.refreshMatches(selecting: .first)

        #expect(controller.matches.map(\.location) == [0, 4, 8, 12])
        #expect(controller.matchCount == 4)
        #expect(controller.activeMatchIndex == 0)
        #expect(controller.activeMatchNumber == 1)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 3))
        #expect(controller.nextMatchRange(startingAt: 1) == NSRange(location: 4, length: 3))
        #expect(controller.previousMatchRange(upTo: 11) == NSRange(location: 8, length: 3))
        #expect(controller.countMatches() == 4)
    }

    @Test func caseSensitiveSearchOnlyMatchesExactCase() {
        let textView = makeTextView("Cat cat CAT catalog")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "cat"
        controller.isCaseSensitive = true

        controller.refreshMatches(selecting: .first)

        #expect(controller.matches.map(\.location) == [4, 12])
        #expect(controller.matchCount == 2)
        #expect(controller.activeMatchIndex == 0)
        #expect(textView.selectedRange() == NSRange(location: 4, length: 3))
        #expect(controller.nextMatchRange(startingAt: 0) == NSRange(location: 4, length: 3))
        #expect(controller.previousMatchRange(upTo: 12) == NSRange(location: 4, length: 3))
        #expect(controller.countMatches() == 2)
    }

    @Test func findNextJumpsToMatch() {
        let textView = makeTextView("hello world hello")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "world"

        let range = controller.nextMatchRange(startingAt: 0)

        #expect(range != nil)
        #expect(range?.location == 6)
        #expect(range?.length == 5)
    }

    @Test func findPreviousJumpsBackwards() {
        let textView = makeTextView("hello world hello")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "hello"

        let range = controller.previousMatchRange(upTo: 17)

        #expect(range != nil)
        #expect(range?.location == 12)
        #expect(range?.length == 5)
    }

    @Test func selectNextWrapsToFirstMatch() {
        let textView = makeTextView("one two one")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "one"

        controller.refreshMatches(selecting: .first)
        #expect(controller.selectNext() == true)
        #expect(controller.activeMatchIndex == 1)
        #expect(textView.selectedRange() == NSRange(location: 8, length: 3))

        #expect(controller.selectNext() == true)
        #expect(controller.activeMatchIndex == 0)
        #expect(controller.activeMatchNumber == 1)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 3))
    }

    @Test func selectPreviousWrapsToLastMatch() {
        let textView = makeTextView("one two one")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "one"

        controller.refreshMatches(selecting: .first)

        #expect(controller.selectPrevious() == true)
        #expect(controller.activeMatchIndex == 1)
        #expect(controller.activeMatchNumber == 2)
        #expect(textView.selectedRange() == NSRange(location: 8, length: 3))
    }

    @Test func emptyQueryClearsMatches() {
        let textView = makeTextView("one two one")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "one"
        controller.refreshMatches(selecting: .first)

        controller.findString = ""
        controller.refreshMatches(selecting: .first)

        #expect(controller.matches.isEmpty)
        #expect(controller.matchCount == 0)
        #expect(controller.activeMatchIndex == nil)
        #expect(controller.activeMatchNumber == nil)
        #expect(controller.selectNext() == false)
        #expect(controller.selectPrevious() == false)
    }

    @Test func replaceCurrentStartsFromCursor() {
        let textView = makeTextView("aa bb aa bb")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "aa"
        controller.replacementString = "xx"

        #expect(controller.replaceCurrent() == true)
        #expect(textView.string == "xx bb aa bb")

        textView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(controller.replaceCurrent() == true)
        #expect(textView.string == "xx bb xx bb")
    }

    @Test func replaceCurrentWrapsAround() {
        let textView = makeTextView("aa bb aa")
        textView.setSelectedRange(NSRange(location: 7, length: 0))
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "aa"
        controller.replacementString = "xx"

        #expect(controller.replaceCurrent() == true)
        #expect(textView.string == "xx bb aa")
    }

    @Test func replaceCurrentUsesCaseInsensitiveSelectedMatchAndRecomputes() {
        let textView = makeTextView("Cat cat CAT")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "cat"
        controller.replacementString = "dog"
        controller.refreshMatches(selecting: .first)

        #expect(controller.replaceCurrent() == true)

        #expect(textView.string == "dog cat CAT")
        #expect(controller.matches.map(\.location) == [4, 8])
        #expect(controller.matchCount == 2)
        #expect(controller.activeMatchIndex == 0)
        #expect(controller.activeMatchNumber == 1)
        #expect(textView.selectedRange() == NSRange(location: 4, length: 3))
    }

    @Test func replaceAllIsCaseInsensitiveByDefault() {
        let textView = makeTextView("Cat cat CAT")
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "cat"
        controller.replacementString = "dog"
        controller.refreshMatches(selecting: .first)

        let count = controller.replaceAll()

        #expect(count == 3)
        #expect(textView.string == "dog dog dog")
        #expect(controller.matches.isEmpty)
        #expect(controller.matchCount == 0)
        #expect(controller.activeMatchIndex == nil)
    }

    @Test func replaceCurrentNoOpOnReadOnly() {
        let textView = makeTextView("hello world")
        textView.isEditable = false
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "world"
        controller.replacementString = "universe"

        #expect(controller.replaceCurrent() == false)
        #expect(textView.string == "hello world")
    }

    @Test func replaceAllNoOpOnReadOnly() {
        let textView = makeTextView("hello hello")
        textView.isEditable = false
        let controller = EditorFindController()
        controller.textView = textView
        controller.findString = "hello"
        controller.replacementString = "bye"

        #expect(controller.replaceAll() == 0)
        #expect(textView.string == "hello hello")
    }
}
