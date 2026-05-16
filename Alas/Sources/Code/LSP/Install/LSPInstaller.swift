import Foundation
import Observation

/// Orchestrates installation of one language server at a time. UI observes
/// `state` and `logLines` for live updates; consumers call `install(...)`
/// to start, `cancel()` to abort.
///
/// Runs on the main actor — this matches the rest of AppState. The actual
/// `Process` spawn is delegated to a detached `Task` so the main actor isn't
/// blocked on I/O; the spawn task feeds back into the installer via
/// `@MainActor` hops.
@Observable
@MainActor
final class LSPInstaller {
    enum State: Equatable, Sendable {
        case idle
        case running(language: String, commandLine: String)
        case finished(language: String, exitCode: Int32)
        case cancelled(language: String)
        case failed(language: String, message: String)
    }

    private(set) var state: State = .idle
    private(set) var logLines: [String] = []

    /// Pure: builds the argv for spawning. Extracted so tests can verify
    /// command shape without spawning a real process.
    nonisolated static func argv(
        for recipe: InstallRecipe,
        using installer: DetectedInstaller
    ) -> (executable: String, arguments: [String]) {
        let exec = installer.executable
        switch installer.kind {
        case .brew:
            return (exec, ["install", recipe.package])
        case .npm:
            return (exec, ["install", "-g", recipe.package])
        case .pnpm:
            return (exec, ["add", "-g", recipe.package])
        case .bun:
            return (exec, ["add", "-g", recipe.package])
        case .cargo:
            return (exec, ["install", recipe.package])
        case .rustup:
            assert(!recipe.extraArgs.isEmpty, "rustup recipe must supply extraArgs")
            return (exec, recipe.extraArgs)
        case .go:
            return (exec, ["install", "\(recipe.package)@latest"])
        case .pipx:
            return (exec, ["install", recipe.package])
        }
    }

    /// Human-readable command line shown above the log in the progress sheet.
    /// Uses the installer's basename, not the full path, to keep it readable.
    nonisolated static func displayCommandLine(
        for recipe: InstallRecipe,
        using installer: DetectedInstaller
    ) -> String {
        let argv = argv(for: recipe, using: installer)
        let basename = (argv.executable as NSString).lastPathComponent
        return ([basename] + argv.arguments).joined(separator: " ")
    }
}
