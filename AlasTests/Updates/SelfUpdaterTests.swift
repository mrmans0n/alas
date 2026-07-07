import Foundation
import Testing
@testable import Alas

@Suite("SelfUpdater")
struct SelfUpdaterTests {
    @Test("homebrew command refreshes the tap before upgrading")
    func homebrewCommandShape() {
        let command = SelfUpdateCommand.homebrew
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments.count == 2)
        #expect(command.arguments[0] == "-c")

        let steps = command.arguments[1].components(separatedBy: " && ")
        #expect(steps.count == 2)
        #expect(steps[0].hasSuffix("brew update"))
        #expect(steps[1].hasSuffix("brew upgrade --cask mrmans0n/tap/alas"))
        // Both steps must invoke the same resolved brew executable.
        #expect(steps[0].dropLast("update".count) == steps[1].dropLast("upgrade --cask mrmans0n/tap/alas".count))

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
        await updater.runForTesting(executable: "/bin/sleep", arguments: ["30"])

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
        await updater.runForTesting(executable: "/bin/sleep", arguments: ["10"])
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
