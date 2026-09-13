import Testing
@testable import Alas

@Suite("Editor navigation history")
struct EditorNavigationHistoryTests {
    private let document = EditorDocumentID(host: nil, worktreeID: "w", uri: "file:///a.swift")

    @Test @MainActor func backReturnsSource() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)

        store.recordJump(from: a, to: b)

        #expect(store.goBack() == a)
        #expect(store.goForward() == b)
    }

    @Test @MainActor func successfulJumpAfterBackTruncatesForwardHistory() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)
        let c = target(line: 16)

        store.recordJump(from: a, to: b)
        store.recordJump(from: b, to: c)
        #expect(store.goBack() == b)

        store.recordJump(from: b, to: a)

        #expect(store.goForward() == nil)
        #expect(store.goBack() == b)
    }

    @Test @MainActor func duplicateJumpDoesNotCreateAHistoryEntry() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)

        store.recordJump(from: a, to: b)
        store.recordJump(from: b, to: b)

        #expect(store.goBack() == a)
        #expect(store.goBack() == nil)
    }

    @Test @MainActor func unavailableTargetRemainsInHistoryUntilActivationSucceeds() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let unavailable = target(line: 8)

        store.recordJump(from: a, to: unavailable)
        store.recordActivationFailure(for: unavailable)

        #expect(store.goBack() == a)
        #expect(store.goForward() == unavailable)
        #expect(store.statusMessage == "Could not open navigation target")
    }

    @Test @MainActor func failedBackActivationRestoresTheCurrentHistoryLocation() {
        let store = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)

        store.recordJump(from: a, to: b)
        #expect(store.goBack() == a)
        store.recordActivationFailure(for: a)

        #expect(store.goForward() == nil)
        #expect(store.goBack() == a)
    }

    @Test @MainActor func historiesAreIndependentForEachWorktreeStore() {
        let first = EditorNavigationStore()
        let second = EditorNavigationStore()
        let a = target(line: 0)
        let b = target(line: 8)

        first.recordJump(from: a, to: b)

        #expect(second.goBack() == nil)
        #expect(first.goBack() == a)
    }

    @Test @MainActor func historyKeepsOnlyTheMostRecentTwoHundredLocations() {
        let store = EditorNavigationStore()
        var previous = target(line: 0)
        for line in 1 ... 200 {
            let next = target(line: line)
            store.recordJump(from: previous, to: next)
            previous = next
        }

        var firstReachable: EditorNavigationTarget?
        while let target = store.goBack() {
            firstReachable = target
        }

        #expect(firstReachable == target(line: 1))
    }

    @Test @MainActor func editedReferenceResultsStayBrowsableAndBecomeStale() {
        let store = EditorNavigationStore()
        let result = target(line: 8)

        store.replaceResults([result])
        store.markResultsStale()

        #expect(store.results == [result])
        #expect(store.resultsAreStale)
    }

    private func target(line: Int) -> EditorNavigationTarget {
        EditorNavigationTarget(document: document, position: LSPPosition(line: line, character: 0))
    }
}
