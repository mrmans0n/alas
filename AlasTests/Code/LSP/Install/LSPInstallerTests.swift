import Foundation
import Testing
@testable import Alas

@Suite("LSPInstaller")
struct LSPInstallerTests {
    @Test("brew install <pkg>")
    func brewArgv() {
        let installer = DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")
        let recipe = InstallRecipe(installer: .brew, package: "rust-analyzer")
        let argv = LSPInstaller.argv(for: recipe, using: installer)
        #expect(argv.executable == "/opt/homebrew/bin/brew")
        #expect(argv.arguments == ["install", "rust-analyzer"])
    }

    @Test("npm install -g <pkg>")
    func npmArgv() {
        let installer = DetectedInstaller(kind: .npm, executable: "/usr/local/bin/npm")
        let recipe = InstallRecipe(installer: .npm, package: "typescript-language-server")
        let argv = LSPInstaller.argv(for: recipe, using: installer)
        #expect(argv.arguments == ["install", "-g", "typescript-language-server"])
    }

    @Test("pnpm add -g <pkg>")
    func pnpmArgv() {
        let installer = DetectedInstaller(kind: .pnpm, executable: "/usr/local/bin/pnpm")
        let recipe = InstallRecipe(installer: .pnpm, package: "typescript-language-server")
        let argv = LSPInstaller.argv(for: recipe, using: installer)
        #expect(argv.arguments == ["add", "-g", "typescript-language-server"])
    }

    @Test("bun add -g <pkg>")
    func bunArgv() {
        let installer = DetectedInstaller(kind: .bun, executable: "/Users/x/.bun/bin/bun")
        let recipe = InstallRecipe(installer: .bun, package: "typescript-language-server")
        let argv = LSPInstaller.argv(for: recipe, using: installer)
        #expect(argv.arguments == ["add", "-g", "typescript-language-server"])
    }

    @Test("cargo install <pkg>")
    func cargoArgv() {
        let installer = DetectedInstaller(kind: .cargo, executable: "/Users/x/.cargo/bin/cargo")
        let recipe = InstallRecipe(installer: .cargo, package: "marksman")
        let argv = LSPInstaller.argv(for: recipe, using: installer)
        #expect(argv.arguments == ["install", "marksman"])
    }

    @Test("rustup uses extraArgs verbatim")
    func rustupArgv() {
        let installer = DetectedInstaller(kind: .rustup, executable: "/Users/x/.cargo/bin/rustup")
        let recipe = InstallRecipe(installer: .rustup, package: "", extraArgs: ["component", "add", "rust-analyzer"])
        let argv = LSPInstaller.argv(for: recipe, using: installer)
        #expect(argv.arguments == ["component", "add", "rust-analyzer"])
    }

    @Test("go install <pkg>@latest")
    func goArgv() {
        let installer = DetectedInstaller(kind: .go, executable: "/usr/local/go/bin/go")
        let recipe = InstallRecipe(installer: .go, package: "golang.org/x/tools/gopls")
        let argv = LSPInstaller.argv(for: recipe, using: installer)
        #expect(argv.arguments == ["install", "golang.org/x/tools/gopls@latest"])
    }

    @Test("pipx install <pkg>")
    func pipxArgv() {
        let installer = DetectedInstaller(kind: .pipx, executable: "/usr/local/bin/pipx")
        let recipe = InstallRecipe(installer: .pipx, package: "pyright")
        let argv = LSPInstaller.argv(for: recipe, using: installer)
        #expect(argv.arguments == ["install", "pyright"])
    }

    @Test("displayCommandLine renders shell-style")
    func displayCommandLine() {
        let installer = DetectedInstaller(kind: .brew, executable: "/opt/homebrew/bin/brew")
        let recipe = InstallRecipe(installer: .brew, package: "rust-analyzer")
        let line = LSPInstaller.displayCommandLine(for: recipe, using: installer)
        #expect(line == "brew install rust-analyzer")
    }

    @Test("displayCommandLine strips deep installer paths to basename")
    func displayCommandLineDeepPath() {
        let installer = DetectedInstaller(kind: .rustup, executable: "/Users/x/.cargo/bin/rustup")
        let recipe = InstallRecipe(installer: .rustup, package: "", extraArgs: ["component", "add", "rust-analyzer"])
        let line = LSPInstaller.displayCommandLine(for: recipe, using: installer)
        #expect(line == "rustup component add rust-analyzer")
    }

    @Test("install with /bin/echo transitions idle → running → finished(0)")
    @MainActor
    func installEchoSucceeds() async throws {
        let installer = LSPInstaller()
        // Use a fake installer that points at /bin/echo so we don't need brew etc.
        // The argv builder uses installer.kind for argv shape, so we work around
        // by going through the lower-level `_spawn` test helper (added below).
        await installer._spawnForTesting(
            executable: "/bin/echo",
            arguments: ["hello"],
            language: "test"
        )

        // Wait briefly for the process to finish (echo is fast).
        for _ in 0..<50 {
            if case .finished = installer.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        if case .finished(let lang, let code) = installer.state {
            #expect(lang == "test")
            #expect(code == 0)
        } else {
            Issue.record("expected finished state, got \(installer.state)")
        }

        #expect(installer.logLines.joined(separator: "\n").contains("hello"))
    }

    @Test("cancel transitions running → cancelled")
    @MainActor
    func cancelInstall() async throws {
        let installer = LSPInstaller()
        // /bin/sleep 30 — long enough for us to cancel
        await installer._spawnForTesting(
            executable: "/bin/sleep",
            arguments: ["30"],
            language: "test"
        )

        // Wait until state flips to .running
        for _ in 0..<50 {
            if case .running = installer.state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .running = installer.state { } else {
            Issue.record("expected running state, got \(installer.state)")
            return
        }

        installer.cancel()

        // Wait for state to become cancelled or failed
        for _ in 0..<200 {  // up to 10s — beyond SIGTERM→SIGKILL escalation
            if case .cancelled = installer.state { return }
            if case .failed = installer.state { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        Issue.record("install did not cancel within timeout, state = \(installer.state)")
    }

    @Test("reset returns state to idle")
    @MainActor
    func resetClears() async {
        let installer = LSPInstaller()
        await installer._spawnForTesting(
            executable: "/bin/echo",
            arguments: ["x"],
            language: "test"
        )
        for _ in 0..<50 {
            if case .finished = installer.state { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        installer.reset()
        #expect(installer.state == .idle)
        #expect(installer.logLines.isEmpty)
    }
}
