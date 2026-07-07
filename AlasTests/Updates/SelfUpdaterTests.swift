import Foundation
import Testing
@testable import Alas

@Suite("SelfUpdater")
struct SelfUpdaterTests {
    @Test("homebrew command refreshes the tap before upgrading, as two direct steps")
    func homebrewCommandShape() {
        let command = SelfUpdateCommand.homebrew
        #expect(command.steps.count == 2)
        #expect(command.steps[0].arguments == ["update"])
        #expect(command.steps[1].arguments == ["upgrade", "--cask", "mrmans0n/tap/alas"])
        // Both steps must invoke the same resolved brew executable directly
        // (no shell wrapper), so cancellation always signals the real process.
        #expect(command.steps[0].executable == command.steps[1].executable)

        #expect(command.displayCommandLine == "brew update && brew upgrade --cask mrmans0n/tap/alas")
    }

    @Test("echo transitions idle → running → finished(0)")
    @MainActor
    func echoSucceeds() async throws {
        let updater = SelfUpdater()
        await updater.runForTesting(executable: "/bin/echo", arguments: ["updated"])

        for _ in 0..<50 {
            if case .finished = updater.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        if case .finished(let code) = updater.state {
            #expect(code == 0)
        } else {
            Issue.record("expected finished, got \(updater.state)")
        }
        #expect(updater.logLines.joined(separator: "\n").contains("updated"))
    }

    @Test("cancel transitions running → cancelled")
    @MainActor
    func cancelRunning() async throws {
        let updater = SelfUpdater()
        Task { await updater.runForTesting(executable: "/bin/sleep", arguments: ["30"]) }

        for _ in 0..<50 {
            if case .running = updater.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .running = updater.state { } else {
            Issue.record("expected running state, got \(updater.state)")
            return
        }

        updater.cancel()

        for _ in 0..<200 {
            if case .cancelled = updater.state { return }
            if case .failed = updater.state { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("update did not cancel within timeout, state = \(updater.state)")
    }

    @Test("multi-step sequence runs steps in order and finishes(0)")
    @MainActor
    func multiStepSequenceRunsInOrder() async throws {
        let updater = SelfUpdater()
        await updater.runForTesting(steps: [
            .init(executable: "/bin/echo", arguments: ["first"]),
            .init(executable: "/bin/echo", arguments: ["second"]),
        ])

        for _ in 0..<50 {
            if case .finished = updater.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        if case .finished(let code) = updater.state {
            #expect(code == 0)
        } else {
            Issue.record("expected finished, got \(updater.state)")
        }
        let log = updater.logLines.joined(separator: "\n")
        #expect(log.contains("first"))
        #expect(log.contains("second"))
    }

    @Test("a failing step stops the sequence before later steps run")
    @MainActor
    func failingStepStopsSequence() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-selfupdater-test-\(UUID().uuidString)")
        let updater = SelfUpdater()
        await updater.runForTesting(steps: [
            .init(executable: "/usr/bin/false", arguments: []),
            .init(executable: "/usr/bin/touch", arguments: [marker.path]),
        ])

        for _ in 0..<50 {
            if case .finished = updater.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        if case .finished(let code) = updater.state {
            #expect(code != 0)
        } else {
            Issue.record("expected finished, got \(updater.state)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("cancelling the first step prevents the second step from ever running")
    @MainActor
    func cancelBetweenStepsStopsSequence() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-selfupdater-test-\(UUID().uuidString)")
        let updater = SelfUpdater()
        Task {
            await updater.runForTesting(steps: [
                .init(executable: "/bin/sleep", arguments: ["30"]),
                .init(executable: "/usr/bin/touch", arguments: [marker.path]),
            ])
        }

        for _ in 0..<50 {
            if case .running = updater.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .running = updater.state { } else {
            Issue.record("expected running state, got \(updater.state)")
            return
        }

        updater.cancel()

        for _ in 0..<200 {
            if case .cancelled = updater.state { break }
            if case .failed = updater.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .cancelled = updater.state {
            // expected
        } else {
            Issue.record("update did not cancel within timeout, state = \(updater.state)")
        }

        // Give a stray second step a moment to run if the bug regressed.
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("missing executable transitions to .failed")
    @MainActor
    func missingExecutableFails() async {
        let updater = SelfUpdater()
        await updater.runForTesting(executable: "/bin/does-not-exist", arguments: [])
        if case .failed = updater.state {
            // expected
        } else {
            Issue.record("expected .failed state, got \(updater.state)")
        }
    }

    @Test("reset returns state to idle")
    @MainActor
    func resetClears() async {
        let updater = SelfUpdater()
        await updater.runForTesting(executable: "/bin/echo", arguments: ["x"])
        for _ in 0..<50 {
            if case .finished = updater.state { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        updater.reset()
        #expect(updater.state == .idle)
        #expect(updater.logLines.isEmpty)
    }

    @Test("start while running throws SelfUpdaterBusy")
    @MainActor
    func startWhileRunningThrows() async throws {
        let updater = SelfUpdater()
        Task { await updater.runForTesting(executable: "/bin/sleep", arguments: ["10"]) }
        for _ in 0..<50 {
            if case .running = updater.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        do {
            try await updater.start(command: .homebrew)
            Issue.record("expected SelfUpdaterBusy to be thrown")
        } catch is SelfUpdaterBusy {
            // expected
        } catch {
            Issue.record("expected SelfUpdaterBusy, got \(error)")
        }

        updater.cancel()
        for _ in 0..<200 {
            if case .cancelled = updater.state { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
