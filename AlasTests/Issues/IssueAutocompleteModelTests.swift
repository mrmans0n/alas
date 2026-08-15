import Foundation
import Testing
@testable import Alas

@MainActor
struct IssueAutocompleteModelTests {
    @Test func hashLoadsOnceAndFiltersByNumberPrefixOrTitle() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled()
        await loader.finish(with: [Self.issue142, Self.issue42, Self.issue7])
        await model.waitForCurrentLoadForTesting()
        #expect(model.filteredSuggestions.map(\.number) == [142, 42, 7])

        model.referenceChanged("#42", projectID: "alas")
        #expect(model.filteredSuggestions.map(\.number) == [42])

        model.referenceChanged("#sync", projectID: "alas")
        #expect(model.filteredSuggestions.map(\.number) == [142, 7])
        #expect(await loader.callCount == 1)
    }

    @Test func URLsAndPlainTextNeverLoadOrPresent() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("https://example.com/tickets/42", projectID: "alas")
        model.referenceChanged("42", projectID: "alas")

        #expect(!model.isPresented)
        #expect(await loader.callCount == 0)
    }

    @Test func filteringMatchesTitlesCaseInsensitivelyIncludingNumericText() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled()
        await loader.finish(with: [Self.issue142, Self.issue42, Self.issue7])
        await model.waitForCurrentLoadForTesting()

        model.referenceChanged("#SYNC", projectID: "alas")
        #expect(model.filteredSuggestions.map(\.number) == [142, 7])

        model.referenceChanged("#42", projectID: "alas")
        #expect(model.filteredSuggestions.map(\.number) == [42])

        model.referenceChanged("#7", projectID: "alas")
        #expect(model.filteredSuggestions.map(\.number) == [42, 7])
    }

    @Test func emptySuccessfulResultsRemainPresented() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled()
        await loader.finish(with: [])
        await model.waitForCurrentLoadForTesting()

        #expect(model.state == .loaded([]))
        #expect(model.filteredSuggestions.isEmpty)
        #expect(model.isPresented)
    }

    @Test func loadingAndFailureRemainPresented() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled()
        #expect(model.state == .loading)
        #expect(model.isPresented)

        await loader.finish(throwing: LoadFailure.unavailable)
        await model.waitForCurrentLoadForTesting()
        guard case .failed = model.state else {
            Issue.record("Expected a failed state, got \(model.state)")
            return
        }
        #expect(model.isPresented)
    }

    @Test func selectionClampsToFilteredSuggestions() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled()
        await loader.finish(with: [Self.issue142, Self.issue42, Self.issue7])
        await model.waitForCurrentLoadForTesting()

        model.moveSelection(8)
        #expect(model.selectedIndex == 2)
        model.moveSelection(-8)
        #expect(model.selectedIndex == 0)

        model.referenceChanged("#42", projectID: "alas")
        #expect(model.selectedIndex == 0)
        model.moveSelection(1)
        #expect(model.selectedIndex == 1)
        model.referenceChanged("#missing", projectID: "alas")
        model.moveSelection(1)
        #expect(model.selectedIndex == 0)
    }

    @Test func acceptingSelectionReturnsReferenceAndDismisses() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled()
        await loader.finish(with: [Self.issue142, Self.issue42])
        await model.waitForCurrentLoadForTesting()
        model.moveSelection(1)

        #expect(model.acceptSelection() == "#42")
        #expect(model.reference == "#42")
        #expect(!model.isPresented)
    }

    @Test func dismissalPersistsUntilReferenceChanges() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled()
        await loader.finish(with: [Self.issue42])
        await model.waitForCurrentLoadForTesting()

        model.dismiss()
        #expect(!model.isPresented)
        model.referenceChanged("#", projectID: "alas")
        #expect(!model.isPresented)
        model.referenceChanged("#4", projectID: "alas")
        #expect(model.isPresented)
    }

    @Test func changingProjectInvalidatesCacheAndLoadsForNewProject() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled(1)
        await loader.finish(call: 1, with: [Self.issue42])
        await model.waitForCurrentLoadForTesting()

        model.referenceChanged("#", projectID: "other")
        await loader.waitUntilCalled(2)
        #expect(model.state == .loading)
        await loader.finish(call: 2, with: [Self.issue7])
        await model.waitForCurrentLoadForTesting()
        #expect(model.filteredSuggestions.map(\.number) == [7])
        #expect(await loader.projectIDs == ["alas", "other"])
    }

    @Test func projectChangeCancelsOldLoadAndRejectsLateResult() async {
        let loader = ControlledLoader()
        let model = IssueAutocompleteModel(load: loader.load)

        model.referenceChanged("#", projectID: "alas")
        await loader.waitUntilCalled(1)
        model.referenceChanged("#", projectID: "other")
        await loader.waitUntilCalled(2)
        await loader.waitUntilCancelled(1)

        await loader.finish(call: 2, with: [Self.issue7])
        await model.waitForCurrentLoadForTesting()
        await loader.finish(call: 1, with: [Self.issue42])
        await Self.drainMainActor()

        #expect(model.state == .loaded([Self.issue7]))
        #expect(model.filteredSuggestions.map(\.number) == [7])
    }

    private static let issue142 = issue(142, "Fix sync latency")
    private static let issue42 = issue(42, "Improve 7 search")
    private static let issue7 = issue(7, "Sync jobs")

    private static func issue(_ number: Int, _ title: String) -> CodeHostIssueSuggestion {
        CodeHostIssueSuggestion(
            provider: .github,
            number: number,
            title: title,
            canonicalURL: URL(string: "https://github.com/acme/alas/issues/\(number)")!,
            createdAt: .distantPast
        )
    }

    private static func drainMainActor() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

private enum LoadFailure: LocalizedError {
    case unavailable

    var errorDescription: String? { "Issue suggestions are unavailable." }
}

private actor ControlledLoader {
    private var calls: [(projectID: String, limit: Int)] = []
    private var cancelledCalls: Set<Int> = []
    private var callWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var cancellationWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var continuations: [Int: CheckedContinuation<[CodeHostIssueSuggestion], Error>] = [:]

    nonisolated func load(projectID: String, limit: Int) async throws -> [CodeHostIssueSuggestion] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await self.begin(projectID: projectID, limit: limit, continuation: continuation) }
            }
        } onCancel: {
            Task { await self.cancelCall(for: projectID) }
        }
    }

    var callCount: Int { calls.count }
    var projectIDs: [String] { calls.map(\.projectID) }

    func waitUntilCalled(_ call: Int = 1) async {
        guard calls.count < call else { return }
        await withCheckedContinuation { continuation in
            callWaiters[call, default: []].append(continuation)
        }
    }

    func waitUntilCancelled(_ call: Int) async {
        guard !cancelledCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters[call, default: []].append(continuation)
        }
    }

    func finish(call: Int = 1, with suggestions: [CodeHostIssueSuggestion]) {
        continuations.removeValue(forKey: call)?.resume(returning: suggestions)
    }

    func finish(call: Int = 1, throwing error: Error) {
        continuations.removeValue(forKey: call)?.resume(throwing: error)
    }

    private func begin(
        projectID: String,
        limit: Int,
        continuation: CheckedContinuation<[CodeHostIssueSuggestion], Error>
    ) {
        calls.append((projectID, limit))
        let call = calls.count
        continuations[call] = continuation
        let waiters = callWaiters.removeValue(forKey: call) ?? []
        waiters.forEach { $0.resume() }
    }

    private func cancelCall(for projectID: String) {
        guard let call = calls.lastIndex(where: { $0.projectID == projectID }).map({ $0 + 1 }) else {
            return
        }
        cancelledCalls.insert(call)
        let waiters = cancellationWaiters.removeValue(forKey: call) ?? []
        waiters.forEach { $0.resume() }
    }
}
