import Foundation
import Testing
@testable import Alas

@MainActor
struct RunFailureBriefCoordinatorTests {
    private static let log = "Compiling\nerror: cannot find 'baz' in scope\nDone"
    private static let brief = RunFailureBrief(summary: "Build failed.", cause: "baz is undefined.", checks: ["Whether baz was renamed."])

    @Test
    func aNewerRunOfTheSameScriptInvalidatesAnInFlightBriefAndDropsItsLateResult() async throws {
        let coordinator = RunFailureBriefCoordinator()
        let generator = ControlledBriefGenerator()
        coordinator.start(Self.failure("old"), loadOutput: { Self.log }, generate: generator.generate)
        await generator.nextCall()

        coordinator.cancelInFlight(worktreeID: "wt", scriptKey: "test")
        generator.resolve(0, with: Self.brief)
        await coordinator.awaitSettled(runID: "old")

        let state = try #require(coordinator.state(for: "old"))
        guard case let .unavailable(excerpt) = state else {
            Issue.record("expected unavailable, got \(state)")
            return
        }
        #expect(excerpt?.lines.map(\.number) == [1, 2, 3])
    }

    @Test
    func aDismissedFailureDropsItsBriefEvenWhenTheResultArrivesLater() async {
        let coordinator = RunFailureBriefCoordinator()
        let generator = ControlledBriefGenerator()
        coordinator.start(Self.failure("run"), loadOutput: { Self.log }, generate: generator.generate)
        await generator.nextCall()

        coordinator.retain(runIDs: [])
        generator.resolve(0, with: Self.brief)
        await coordinator.awaitSettled(runID: "run")

        #expect(coordinator.state(for: "run") == nil)
    }

    @Test
    func aCompletedBriefSurvivesALaterRunButNotItsFailureLeavingTheQueue() async throws {
        let coordinator = RunFailureBriefCoordinator()
        let generator = ControlledBriefGenerator()
        coordinator.start(Self.failure("run"), loadOutput: { Self.log }, generate: generator.generate)
        await generator.nextCall()
        generator.resolve(0, with: Self.brief)
        await coordinator.awaitSettled(runID: "run")

        coordinator.cancelInFlight(worktreeID: "wt", scriptKey: "test")
        let excerpt = try #require(FailureLogSelection.select(Self.log))
        #expect(coordinator.state(for: "run") == .ready(excerpt, Self.brief))

        coordinator.retain(runIDs: [])
        #expect(coordinator.state(for: "run") == nil)
    }

    @Test
    func withoutAModelTheObservedExcerptIsStillAvailable() async throws {
        let coordinator = RunFailureBriefCoordinator()

        coordinator.start(Self.failure("run"), loadOutput: { Self.log }, generate: nil)
        await coordinator.awaitSettled(runID: "run")

        let excerpt = try #require(FailureLogSelection.select(Self.log))
        #expect(coordinator.state(for: "run") == .unavailable(excerpt))
    }

    private static func failure(_ runID: String) -> RunScriptFailure {
        RunScriptFailure(
            id: runID, runID: runID, scriptKey: "test", scriptName: "Test",
            worktreeID: "wt", branch: "main", exitCode: 1, completedAt: Date()
        )
    }
}

@MainActor
private final class ControlledBriefGenerator {
    private var continuations: [CheckedContinuation<RunFailureBrief?, Never>] = []
    private var calls: AsyncStream<Void>.Iterator
    private let callContinuation: AsyncStream<Void>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        calls = stream.makeAsyncIterator()
        callContinuation = continuation
    }

    var generate: RunFailureBriefCoordinator.Generate {
        { [self] _ in
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
                callContinuation.yield()
            }
        }
    }

    func nextCall() async {
        var iterator = calls
        _ = await iterator.next(isolation: #isolation)
        calls = iterator
    }

    func resolve(_ index: Int, with brief: RunFailureBrief?) {
        continuations[index].resume(returning: brief)
    }
}
