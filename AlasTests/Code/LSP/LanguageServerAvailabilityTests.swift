import Foundation
import Testing
@testable import Alas

@Suite("LanguageServerAvailability")
struct LanguageServerAvailabilityTests {
    @Test("disabled entries report disabled")
    func disabled() {
        let entry = config(language: "swift", command: "sourcekit-lsp", enabled: false)
        let availability = LanguageServerAvailability(environment: [:], xcrunFind: { _ in true })
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
        let availability = LanguageServerAvailability(environment: [:], xcrunFind: { _ in false })
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
        let availability = LanguageServerAvailability(environment: ["PATH": dir.path], xcrunFind: { _ in false })
        #expect(availability.status(for: entry) == .available)
    }

    @Test("Swift sourcekit-lsp falls back to xcrun")
    func swiftXcrunFallback() {
        var requestedTool: String?
        let entry = config(language: "swift", command: "sourcekit-lsp")
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { tool in
            requestedTool = tool
            return true
        })

        #expect(availability.status(for: entry) == .available)
        #expect(requestedTool == "sourcekit-lsp")
    }

    @Test("xcrun fallback is Swift sourcekit-lsp only")
    func xcrunFallbackIsSwiftOnly() {
        var didCallXcrun = false
        let entry = config(language: "rust", command: "rust-analyzer")
        let availability = LanguageServerAvailability(environment: ["PATH": ""], xcrunFind: { _ in
            didCallXcrun = true
            return true
        })

        #expect(availability.status(for: entry) == .notInstalled)
        #expect(didCallXcrun == false)
    }

    private func config(language: String = "test", command: String, enabled: Bool = true) -> LanguageServerConfig {
        LanguageServerConfig(
            language: language,
            extensions: [language],
            command: command,
            args: [],
            env: [:],
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
