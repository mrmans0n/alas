import Foundation
import Testing
@testable import Alas

@Suite("LanguageServerAvailability")
struct LanguageServerAvailabilityTests {
    @Test("disabled entries report disabled")
    func disabled() {
        let entry = config(language: "swift", command: "sourcekit-lsp", enabled: false)
        let availability = LanguageServerAvailability(environment: [:], xcrunFind: { _ in nil }, additionalPathDirectories: [])
        #expect(availability.status(for: entry) == .disabled)
    }

    @Test("absolute executable path reports available")
    func absoluteExecutable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("server")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(command: executable.path)
        let availability = LanguageServerAvailability(environment: [:], xcrunFind: { _ in nil }, additionalPathDirectories: [])
        #expect(availability.status(for: entry) == .available)
    }

    @Test("bare command resolves against PATH")
    func pathExecutable() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("test-lsp")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(command: "test-lsp")
        let availability = LanguageServerAvailability(environment: ["PATH": dir.path], xcrunFind: { _ in nil }, additionalPathDirectories: [])
        #expect(availability.status(for: entry) == .available)
    }

    @Test("minimal GUI PATH still checks additional tool directories")
    func additionalToolDirectories() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("rust-analyzer")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(language: "rust", command: "rust-analyzer")
        let availability = LanguageServerAvailability(
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            xcrunFind: { _ in nil },
            additionalPathDirectories: ["\(NSHomeDirectory())/.npm-global/bin", dir.path]
        )

        #expect(availability.status(for: entry) == .available)
        #expect(availability.resolvedCommand(for: entry) == executable.path)
    }

    @Test("gui PATH includes npm-global directory")
    func launchEnvironmentIncludesNpmGlobal() {
        let entry = config(command: "custom-lsp")
        let availability = LanguageServerAvailability(
            environment: ["PATH": "/usr/bin:/bin"],
            xcrunFind: { _ in nil },
            additionalPathDirectories: ["\(NSHomeDirectory())/.npm-global/bin", "/opt/homebrew/bin"]
        )

        let env = availability.launchEnvironment(for: entry)
        let path = env["PATH"] ?? ""
        #expect(path.contains("/.npm-global/bin"))
        #expect(path.contains("/opt/homebrew/bin"))
    }

    @Test("Swift sourcekit-lsp falls back to xcrun")
    func swiftXcrunFallback() {
        var requestedTool: String?
        let entry = config(language: "swift", command: "sourcekit-lsp")
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { tool in
            requestedTool = tool
            return "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        }, additionalPathDirectories: [])

        #expect(availability.status(for: entry) == .available)
        #expect(requestedTool == "sourcekit-lsp")
    }

    @Test("xcrun fallback is Swift sourcekit-lsp only")
    func xcrunFallbackIsSwiftOnly() {
        var didCallXcrun = false
        let entry = config(language: "rust", command: "rust-analyzer")
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in
            didCallXcrun = true
            return "/usr/local/bin/rust-analyzer"
        }, additionalPathDirectories: [])

        #expect(availability.status(for: entry) == .notInstalled)
        #expect(didCallXcrun == false)
    }

    @Test("resolvedCommand returns xcrun path for Swift")
    func resolvedCommandXcrun() {
        let entry = config(language: "swift", command: "sourcekit-lsp")
        let xcrunPath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in xcrunPath }, additionalPathDirectories: [])

        #expect(availability.resolvedCommand(for: entry) == xcrunPath)
    }

    @Test("spawnArguments uses absolute path from xcrun")
    func spawnArgumentsXcrun() {
        let entry = config(language: "swift", command: "sourcekit-lsp", args: ["--flag"])
        let xcrunPath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in xcrunPath }, additionalPathDirectories: [])
        let spawn = availability.spawnArguments(for: entry)

        #expect(spawn != nil)
        #expect(spawn!.executable == xcrunPath)
        #expect(spawn!.arguments == ["--flag"])
    }

    @Test("spawnArguments uses resolved absolute path from PATH")
    func spawnArgumentsPathCommand() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("test-lsp")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(command: "test-lsp", args: ["--verbose"])
        let availability = LanguageServerAvailability(environment: ["PATH": dir.path], xcrunFind: { _ in nil }, additionalPathDirectories: [])
        let spawn = availability.spawnArguments(for: entry)

        #expect(spawn != nil)
        #expect(spawn!.executable == executable.path)
        #expect(spawn!.arguments == ["--verbose"])
    }

    @Test("spawnArguments wraps unresolvable bare command with env")
    func spawnArgumentsEnvFallback() {
        let entry = config(command: "missing-lsp", args: ["--flag"])
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in nil }, additionalPathDirectories: [])
        let spawn = availability.spawnArguments(for: entry)

        #expect(spawn == nil)
    }

    @Test("entry.env PATH is merged for resolution")
    func envPathResolution() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let executable = dir.appendingPathComponent("custom-lsp")
        let created = FileManager.default.createFile(atPath: executable.path, contents: Data())
        #expect(created)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let entry = config(command: "custom-lsp", env: ["PATH": dir.path])
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in nil }, additionalPathDirectories: [])
        #expect(availability.status(for: entry) == .available)
    }

    @Test("launch environment uses same augmented PATH as resolution")
    func launchEnvironmentPath() {
        let entry = config(command: "custom-lsp", env: ["PATH": "/custom/bin", "CUSTOM": "1"])
        let availability = LanguageServerAvailability(
            environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"],
            xcrunFind: { _ in nil },
            additionalPathDirectories: ["/opt/homebrew/bin", "/custom/bin"]
        )

        let env = availability.launchEnvironment(for: entry)

        #expect(env["CUSTOM"] == "1")
        #expect(env["HOME"] == "/Users/test")
        #expect(env["PATH"] == "/custom/bin:/usr/bin:/bin:/opt/homebrew/bin")
    }

    private func config(language: String = "test", command: String, args: [String] = [], env: [String: String] = [:], enabled: Bool = true) -> LanguageServerConfig {
        LanguageServerConfig(
            language: language,
            extensions: [language],
            command: command,
            args: args,
            env: env,
            rootMarkers: [],
            enabled: enabled
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlasTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
