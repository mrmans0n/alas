import Foundation
import Testing
@testable import Alas

@Suite("InstallerHost")
struct InstallerHostTests {
    @Test("detects brew at /opt/homebrew/bin")
    func detectsBrew() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "brew", in: dir)

        let host = InstallerHost.detect(
            environment: ["PATH": dir.path],
            additionalPathDirectories: [],
            fileManager: .default
        )

        #expect(host.installer(for: .brew)?.executable == dir.appendingPathComponent("brew").path)
        #expect(host.installer(for: .npm) == nil)
    }

    @Test("detects multiple installers")
    func detectsMultiple() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["brew", "npm", "cargo"] {
            try makeExecutable(named: name, in: dir)
        }

        let host = InstallerHost.detect(
            environment: ["PATH": dir.path],
            additionalPathDirectories: [],
            fileManager: .default
        )

        #expect(host.installer(for: .brew) != nil)
        #expect(host.installer(for: .npm) != nil)
        #expect(host.installer(for: .cargo) != nil)
        #expect(host.installer(for: .pnpm) == nil)
        #expect(host.installer(for: .bun) == nil)
    }

    @Test("falls back to additionalPathDirectories")
    func additionalDirs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "cargo", in: dir)

        let host = InstallerHost.detect(
            environment: ["PATH": "/usr/bin:/bin"],
            additionalPathDirectories: [dir.path],
            fileManager: .default
        )

        #expect(host.installer(for: .cargo)?.executable == dir.appendingPathComponent("cargo").path)
    }

    @Test("firstAvailable walks recipes in order and returns first detected")
    func firstAvailableOrdered() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeExecutable(named: "cargo", in: dir)

        let host = InstallerHost.detect(
            environment: ["PATH": dir.path],
            additionalPathDirectories: [],
            fileManager: .default
        )

        let recipes: [InstallRecipe] = [
            InstallRecipe(installer: .brew, package: "marksman"),
            InstallRecipe(installer: .cargo, package: "marksman"),
        ]
        let result = host.firstAvailable(in: recipes)
        #expect(result != nil)
        #expect(result!.installer.kind == .cargo)
        #expect(result!.recipe.package == "marksman")
    }

    @Test("firstAvailable returns nil when nothing matches")
    func firstAvailableNoMatch() {
        let host = InstallerHost.detect(
            environment: ["PATH": "/usr/bin:/bin"],
            additionalPathDirectories: [],
            fileManager: .default
        )
        let recipes = [InstallRecipe(installer: .pnpm, package: "x")]
        #expect(host.firstAvailable(in: recipes) == nil)
    }

    @Test("allAvailable returns every detected recipe in original order")
    func allAvailable() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["brew", "cargo"] {
            try makeExecutable(named: name, in: dir)
        }

        let host = InstallerHost.detect(
            environment: ["PATH": dir.path],
            additionalPathDirectories: [],
            fileManager: .default
        )

        let recipes: [InstallRecipe] = [
            InstallRecipe(installer: .rustup, package: "", extraArgs: ["component", "add", "rust-analyzer"]),
            InstallRecipe(installer: .brew, package: "rust-analyzer"),
            InstallRecipe(installer: .cargo, package: "rust-analyzer"),
        ]
        let result = host.allAvailable(in: recipes)
        #expect(result.count == 2)
        #expect(result[0].installer.kind == .brew)
        #expect(result[1].installer.kind == .cargo)
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallerHostTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(named name: String, in dir: URL) throws {
        let path = dir.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
