import Foundation
import Observation

/// Drives the "Install gg…" flow in Settings → Changes. Runs Homebrew
/// headless and re-probes availability on success, following the LSP
/// install-nudge pattern.
@MainActor
@Observable
final class GGInstallController {
    enum Phase: Equatable {
        case idle, running, succeeded
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    private let runInstall: @Sendable () async throws -> ProcessResult
    /// Returns whether gg is on PATH after the install. Injectable for tests.
    private let reprobe: @MainActor () async -> Bool

    init(
        runInstall: @escaping @Sendable () async throws -> ProcessResult = {
            try await Process.run(
                "/usr/bin/env",
                args: ["brew", "install", "mrmans0n/tap/gg-stack"],
                env: Process.gitEnv(),
                timeout: 600
            )
        },
        reprobe: @escaping @MainActor () async -> Bool = {
            await GGAvailability.shared.probe(force: true)
            return GGAvailability.shared.isInstalled
        }
    ) {
        self.runInstall = runInstall
        self.reprobe = reprobe
    }

    func install() {
        Task { await installAndWait() }
    }

    func installAndWait() async {
        guard phase != .running else { return }
        phase = .running
        do {
            let result = try await runInstall()
            guard result.exitCode == 0 else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                phase = .failed(stderr.isEmpty ? "brew exited with code \(result.exitCode)." : stderr)
                return
            }
            phase = await reprobe() ? .succeeded : .failed("gg is still not on PATH after install.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
