import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Installs or upgrades a command-line tool with Homebrew, headless, then
/// re-probes that the tool is found. Settings › Changes installs gg with it,
/// and the simulator settings install simslim.
@MainActor
@Observable
public final class HomebrewInstallController {
    public enum Phase: Equatable, Sendable {
        case idle, running, succeeded
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    private let formula: String
    /// Names the tool in messages.
    private let tool: String
    private let runBrew: @Sendable ([String]) async throws -> ProcessResult
    /// Whether the tool is found after the install. Injectable for tests.
    private let reprobe: @MainActor () async -> Bool

    public init(
        formula: String,
        tool: String,
        runBrew: @escaping @Sendable ([String]) async throws -> ProcessResult = { args in
            try await Process.run("/usr/bin/env", args: ["brew"] + args, env: Process.gitEnv(), timeout: 600)
        },
        reprobe: @escaping @MainActor () async -> Bool
    ) {
        self.formula = formula
        self.tool = tool
        self.runBrew = runBrew
        self.reprobe = reprobe
    }

    public func install() {
        Task { await installAndWait() }
    }

    public func installAndWait() async {
        await perform("install")
    }

    public func upgrade() {
        Task { await upgradeAndWait() }
    }

    public func upgradeAndWait() async {
        await perform("upgrade")
    }

    private func perform(_ command: String) async {
        guard phase != .running else { return }
        phase = .running
        do {
            let result = try await runBrew([command, formula])
            guard result.exitCode == 0 else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                phase = .failed(stderr.isEmpty ? "brew exited with code \(result.exitCode)." : stderr)
                return
            }
            phase = await reprobe() ? .succeeded : .failed("\(tool) is still not on PATH after \(command).")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
