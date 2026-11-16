import Foundation
import Testing
@testable import Alas

private actor ControlledUpgradeOperation {
    private var calls = 0
    private var continuation: CheckedContinuation<ProcessResult, Never>?

    func run() async -> ProcessResult {
        calls += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func callCount() -> Int { calls }

    func finish() {
        continuation?.resume(returning: ProcessResult(exitCode: 0, stdout: "upgraded", stderr: ""))
        continuation = nil
    }
}

@MainActor
struct HomebrewInstallControllerTests {
    private func controller(
        brew: @escaping @Sendable ([String]) async throws -> ProcessResult = { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") },
        reprobe: @escaping @MainActor () async -> Bool = { true }
    ) -> HomebrewInstallController {
        HomebrewInstallController(formula: "example/tap/tool", tool: "tool", runBrew: brew, reprobe: reprobe)
    }

    @Test func successfulInstallReachesSucceededAndReprobes() async {
        let calls = BrewCalls()
        var probed = false
        let controller = controller(
            brew: { args in
                calls.append(args)
                return ProcessResult(exitCode: 0, stdout: "installed", stderr: "")
            },
            reprobe: {
                probed = true
                return true
            }
        )
        await controller.installAndWait()
        #expect(controller.phase == .succeeded)
        #expect(calls.all == [["install", "example/tap/tool"]])
        #expect(probed)
    }

    @Test func brewFailureSurfacesStderr() async {
        let controller = controller(brew: { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "no tap") })
        await controller.installAndWait()
        #expect(controller.phase == .failed("no tap"))
    }

    @Test func installedButNotOnPathFails() async {
        let controller = controller(reprobe: { false })
        await controller.installAndWait()
        #expect(controller.phase == .failed("tool is still not on PATH after install."))
    }

    @Test func successfulUpgradeReachesSucceededAndReprobes() async {
        let calls = BrewCalls()
        var probed = false
        let controller = controller(
            brew: { args in
                calls.append(args)
                return ProcessResult(exitCode: 0, stdout: "upgraded", stderr: "")
            },
            reprobe: {
                probed = true
                return true
            }
        )

        await controller.upgradeAndWait()
        #expect(controller.phase == .succeeded)
        #expect(calls.all == [["upgrade", "example/tap/tool"]])
        #expect(probed)
    }

    @Test func upgradeFailureSurfacesStderrWithoutReprobe() async {
        var probed = false
        let controller = controller(
            brew: { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "formula unavailable") },
            reprobe: {
                probed = true
                return true
            }
        )

        await controller.upgradeAndWait()
        #expect(controller.phase == .failed("formula unavailable"))
        #expect(!probed)
    }

    @Test func concurrentUpgradeCallsDeduplicateWhileRunning() async throws {
        let operation = ControlledUpgradeOperation()
        let controller = controller(brew: { _ in await operation.run() })

        let first = Task { await controller.upgradeAndWait() }
        while await operation.callCount() == 0 {
            await Task.yield()
        }
        #expect(controller.phase == .running)

        await controller.upgradeAndWait()
        #expect(await operation.callCount() == 1)

        await operation.finish()
        await first.value
        #expect(controller.phase == .succeeded)
    }
}

/// The arguments each brew run got, from a concurrently-executing closure.
///
/// Safe under `@unchecked Sendable`: `calls` is only ever read or written inside `lock`.
private final class BrewCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []

    func append(_ args: [String]) {
        lock.withLock { calls.append(args) }
    }

    var all: [[String]] {
        lock.withLock { calls }
    }
}
