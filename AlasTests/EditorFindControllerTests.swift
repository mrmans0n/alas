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
}
