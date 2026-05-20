import Foundation
import Testing
@testable import Alas

@Suite("MasonSnapshot")
struct MasonSnapshotTests {
    @Test("snapshot loads from bundle and is non-empty")
    func loadsFromBundle() throws {
        let snap = MasonSnapshot.shared
        #expect(snap.packages.count > 0)
    }

    @Test("search by masonId prefix")
    func searchById() {
        let snap = MasonSnapshot.shared
        let results = snap.search("typescript")
        #expect(results.contains(where: { $0.masonId.contains("typescript") }))
    }

    @Test("search by language matches packages claiming that language")
    func searchByLanguage() {
        let snap = MasonSnapshot.shared
        let results = snap.search("rust")
        #expect(results.contains(where: { $0.languages.contains("Rust") }))
    }

    @Test("empty query returns no results")
    func emptyQuery() {
        #expect(MasonSnapshot.shared.search("").isEmpty)
    }

    @Test("search caps result count")
    func resultCap() {
        // Worst case "e" matches a lot of things — should still be capped.
        let results = MasonSnapshot.shared.search("e")
        #expect(results.count <= MasonSnapshot.maxResults)
    }

    @Test("bundled snapshot includes TOML package")
    func bundledSnapshotIncludesTOML() {
        let results = MasonSnapshot.shared.packages(forFileExtension: "toml")
        let taplo = results.first(where: { $0.masonId == "taplo" })

        #expect(taplo != nil)
        #expect(taplo?.command == "taplo")
        #expect(taplo?.args == ["lsp", "stdio"])
        #expect(taplo?.recipes.contains(where: { $0.installer == .brew && $0.package == "taplo" }) == true)
    }

    @Test("bundled snapshot launches CLI packages in LSP mode")
    func bundledSnapshotLaunchesCLIPackagesInLSPMode() {
        let expected: [String: (String, [String])] = [
            "aiken": ("aiken", ["lsp"]),
            "air": ("air", ["language-server"]),
            "ast-grep": ("ast-grep", ["lsp"]),
            "buf": ("buf", ["lsp", "serve", "--log-format=text"]),
            "clarinet": ("clarinet", ["lsp"]),
            "dexter": ("dexter", ["lsp"]),
            "docker-language-server": ("docker-language-server", ["start", "--stdio"]),
            "dprint": ("dprint", ["lsp"]),
            "erg": ("erg", ["--language-server"]),
            "expert": ("expert", ["--stdio"]),
            "helm-ls": ("helm_ls", ["serve"]),
            "neocmakelsp": ("neocmakelsp", ["--stdio"]),
            "postgres-language-server": ("postgres-language-server", ["lsp-proxy"]),
            "pylyzer": ("pylyzer", ["--server"]),
            "regal": ("regal", ["language-server"]),
            "rumdl": ("rumdl", ["server"]),
            "solidity": ("solc", ["--lsp"]),
            "stylua": ("stylua", ["--lsp"]),
            "superhtml": ("superhtml", ["lsp"]),
            "templ": ("templ", ["lsp"]),
            "tilt": ("tilt", ["lsp", "start"]),
            "tofu-ls": ("tofu-ls", ["serve"]),
            "tombi": ("tombi", ["lsp"]),
            "zk": ("zk", ["lsp"]),
        ]

        for (masonId, command) in expected {
            let package = MasonSnapshot.shared.packages.first(where: { $0.masonId == masonId })
            #expect(package != nil)
            #expect(package?.command == command.0)
            #expect(package?.args == command.1)
        }
    }

    @Test("packages for extension normalizes dot prefix and case")
    func packagesForExtensionNormalizes() {
        let snap = MasonSnapshot(packages: [
            package(id: "taplo", languageId: "toml", extensions: ["toml"]),
            package(id: "json-lsp", languageId: "json", extensions: ["json"]),
        ])

        let results = snap.packages(forFileExtension: ".TOML")

        #expect(results.map(\.masonId) == ["taplo"])
    }

    @Test("packages for extension ignores empty extension")
    func packagesForExtensionEmpty() {
        let snap = MasonSnapshot(packages: [
            package(id: "empty", languageId: "empty", extensions: [""]),
        ])

        #expect(snap.packages(forFileExtension: "").isEmpty)
        #expect(snap.packages(forFileExtension: ".").isEmpty)
    }

    @Test("packages for extension ranks exact language id then configured language")
    func packagesForExtensionRanks() {
        let snap = MasonSnapshot(packages: [
            package(id: "z-no-language", languageId: "", extensions: ["foo"]),
            package(id: "b-other-language", languageId: "bar", extensions: ["foo"]),
            package(id: "a-exact-language", languageId: "foo", extensions: ["foo"]),
        ])

        let results = snap.packages(forFileExtension: "foo")

        #expect(results.map(\.masonId) == [
            "a-exact-language",
            "b-other-language",
            "z-no-language",
        ])
    }

    private func package(
        id: String,
        languageId: String,
        extensions: [String],
        recipes: [InstallRecipe] = [InstallRecipe(installer: .brew, package: "pkg")]
    ) -> MasonPackage {
        MasonPackage(
            masonId: id,
            displayName: id,
            languageId: languageId,
            languages: languageId.isEmpty ? [] : [languageId],
            extensions: extensions,
            command: id,
            args: ["--stdio"],
            recipes: recipes
        )
    }
}
