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
}
