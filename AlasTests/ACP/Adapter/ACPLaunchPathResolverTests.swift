import Foundation
import Testing
@testable import Alas

@Suite("ACPLaunchPathResolver")
struct ACPLaunchPathResolverTests {
    private func makeExecutable(named name: String, inDir dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let exe = dir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return exe
    }

    private func tmp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-launchpath-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("non-npm adapter resolves to nil (PATH launch unchanged)")
    func nonNpmReturnsNil() async throws {
        let gemini = try #require(ACPLaunchCatalog.spec(for: "gemini"))   // .binaryOnPath, npmPackageName == nil
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": "/usr/bin"], additionalPathDirectories: [],
            npmGlobalBinDirectory: { nil })
        let path = await resolver.resolvedLaunchPath(for: gemini)
        #expect(path == nil)
    }

    // codex is `.npxPackage` — the package is the only thing the setup check
    // verifies, so the resolver prefers the package-owned binary (shadow defeat).
    @Test("npxPackage adapter: npm-global binary beats a PATH shadow")
    func npmGlobalWinsOverShadow() async throws {
        let pathDir = tmp()
        let npmBinDir = tmp()
        let shadow = try makeExecutable(named: "codex-acp", inDir: pathDir)
        let owned = try makeExecutable(named: "codex-acp", inDir: npmBinDir)
        defer {
            try? FileManager.default.removeItem(at: pathDir)
            try? FileManager.default.removeItem(at: npmBinDir)
        }
        let codex = try #require(ACPLaunchCatalog.spec(for: "codex"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": pathDir.path], additionalPathDirectories: [],
            npmGlobalBinDirectory: { npmBinDir.path })
        let path = await resolver.resolvedLaunchPath(for: codex)
        #expect(path == owned.path)
        #expect(path != shadow.path)
    }

    @Test("falls back to PATH when no npm-global binary")
    func pathFallback() async throws {
        let pathDir = tmp()
        let onPath = try makeExecutable(named: "codex-acp", inDir: pathDir)
        defer { try? FileManager.default.removeItem(at: pathDir) }
        let codex = try #require(ACPLaunchCatalog.spec(for: "codex"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": pathDir.path], additionalPathDirectories: [],
            npmGlobalBinDirectory: { nil })   // npm-global unavailable
        let path = await resolver.resolvedLaunchPath(for: codex)
        #expect(path == onPath.path)
    }

    // claude is `.binaryOnPathOrNpmPackage` — the setup check verifies the PATH
    // binary first, so the resolver must launch THAT binary (not a different
    // same-named one in npm's global bin), keeping launch == what was verified.
    @Test("binaryOnPathOrNpmPackage adapter: PATH binary wins over npm-global")
    func binaryVerifiedPrefersPath() async throws {
        let pathDir = tmp()
        let npmBinDir = tmp()
        let onPath = try makeExecutable(named: "claude-agent-acp", inDir: pathDir)
        let inNpm = try makeExecutable(named: "claude-agent-acp", inDir: npmBinDir)
        defer {
            try? FileManager.default.removeItem(at: pathDir)
            try? FileManager.default.removeItem(at: npmBinDir)
        }
        let claude = try #require(ACPLaunchCatalog.spec(for: "claude"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": pathDir.path], additionalPathDirectories: [],
            npmGlobalBinDirectory: { npmBinDir.path })
        let path = await resolver.resolvedLaunchPath(for: claude)
        #expect(path == onPath.path)
        #expect(path != inNpm.path)
    }

    // No PATH binary for the binary-or-package adapter → fall back to the
    // npm-global binary (the check would have passed on the package).
    @Test("binaryOnPathOrNpmPackage adapter: falls back to npm-global when no PATH binary")
    func binaryVerifiedFallsBackToNpmGlobal() async throws {
        let npmBinDir = tmp()
        let inNpm = try makeExecutable(named: "claude-agent-acp", inDir: npmBinDir)
        defer { try? FileManager.default.removeItem(at: npmBinDir) }
        let claude = try #require(ACPLaunchCatalog.spec(for: "claude"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": "/var/empty"], additionalPathDirectories: [],
            npmGlobalBinDirectory: { npmBinDir.path })
        let path = await resolver.resolvedLaunchPath(for: claude)
        #expect(path == inNpm.path)
    }

    @Test("nil when nothing resolves")
    func nothingResolves() async throws {
        let codex = try #require(ACPLaunchCatalog.spec(for: "codex"))
        let resolver = ACPLaunchPathResolver(
            env: ["PATH": "/var/empty"], additionalPathDirectories: [],
            npmGlobalBinDirectory: { nil })
        let path = await resolver.resolvedLaunchPath(for: codex)
        #expect(path == nil)
    }
}
