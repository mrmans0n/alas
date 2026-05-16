import Foundation
import Testing
@testable import Alas

@Suite("InstallRecipe")
struct InstallRecipeTests {
    @Test("InstallerKind round-trips through JSON")
    func installerKindCodable() throws {
        let kinds: [InstallerKind] = [.brew, .npm, .pnpm, .bun, .cargo, .rustup, .go, .pipx]
        for kind in kinds {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(InstallerKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    @Test("InstallerKind raw values are stable")
    func installerKindRawValues() {
        #expect(InstallerKind.brew.rawValue == "brew")
        #expect(InstallerKind.npm.rawValue == "npm")
        #expect(InstallerKind.pnpm.rawValue == "pnpm")
        #expect(InstallerKind.bun.rawValue == "bun")
        #expect(InstallerKind.cargo.rawValue == "cargo")
        #expect(InstallerKind.rustup.rawValue == "rustup")
        #expect(InstallerKind.go.rawValue == "go")
        #expect(InstallerKind.pipx.rawValue == "pipx")
    }

    @Test("InstallRecipe round-trips with empty extraArgs")
    func recipeRoundTripDefault() throws {
        let recipe = InstallRecipe(installer: .brew, package: "rust-analyzer", extraArgs: [])
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(InstallRecipe.self, from: data)
        #expect(decoded == recipe)
    }

    @Test("InstallRecipe round-trips with extraArgs (rustup component-add)")
    func recipeRoundTripWithExtraArgs() throws {
        let recipe = InstallRecipe(installer: .rustup, package: "", extraArgs: ["component", "add", "rust-analyzer"])
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(InstallRecipe.self, from: data)
        #expect(decoded == recipe)
        #expect(decoded.extraArgs == ["component", "add", "rust-analyzer"])
    }
}
