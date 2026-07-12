import Foundation
import Testing
import AppKit
@testable import Alas

@MainActor
@Suite(.serialized)
struct FormatOnSaveTests {
    private func tempWorktree() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-format-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ root: URL, _ rel: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeConfig(formatOnSave: Bool) -> AppConfig.Code {
        AppConfig.Code(
            fontFamily: "SF Mono",
            fontSize: 13,
            formatOnSave: formatOnSave,
            showLineNumbers: true,
            languageServers: [],
            dismissedInstallNudges: [],
            userDefinedRecipes: [:]
        )
    }

    @Test func disabledFormatOnSaveDoesPlainSave() async throws {
        let root = tempWorktree()
        try writeFile(root, "a.txt", "hello")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        let formatter = FakeFormatter(edits: [
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 5)), newText: "nope")
        ])
        try await buffer.formatAndSave(config: makeConfig(formatOnSave: false), lsp: formatter)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "HELLO")
    }

    @Test func noLspFallsBackToPlainSave() async throws {
        let root = tempWorktree()
        try writeFile(root, "a.txt", "hello")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        try await buffer.formatAndSave(config: makeConfig(formatOnSave: true), lsp: nil)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "HELLO")
    }

    @Test func formatterEditsAreAppliedBeforeSave() async throws {
        let root = tempWorktree()
        try writeFile(root, "a.txt", "hello")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        let formatter = FakeFormatter(edits: [
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 5)), newText: "formatted")
        ])
        try await buffer.formatAndSave(config: makeConfig(formatOnSave: true), lsp: formatter)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "formatted")
        #expect(formatter.didChangeText == "formatted")
    }

    @Test func formatterFailureFallsBackToPlainSave() async throws {
        let root = tempWorktree()
        try writeFile(root, "a.txt", "hello")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        let formatter = FakeFormatter(throwError: true)
        try await buffer.formatAndSave(config: makeConfig(formatOnSave: true), lsp: formatter)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "HELLO")
    }

    @Test func timeoutFallsBackToPlainSave() async throws {
        let root = tempWorktree()
        try writeFile(root, "a.txt", "hello")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        let formatter = FakeFormatter(delayNanoseconds: 200_000_000)
        try await buffer.formatAndSave(config: makeConfig(formatOnSave: true), lsp: formatter, formattingTimeoutNanoseconds: 20_000_000)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "HELLO")
    }

    @Test func bufferGenerationChangeDiscardsEdits() async throws {
        let root = tempWorktree()
        try writeFile(root, "a.txt", "hello")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        let formatter = FakeFormatter(edits: [
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 5)), newText: "formatted")
        ], delayNanoseconds: 500_000_000)
        Task { @MainActor in
            try await Task.sleep(nanoseconds: 100_000_000)
            buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        }
        try await buffer.formatAndSave(config: makeConfig(formatOnSave: true), lsp: formatter)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "xHELLO")
    }

    @Test func invalidFormatterEditFallsBackWithoutPartialMutation() async throws {
        let root = tempWorktree()
        try writeFile(root, "a.txt", "hello")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        let formatter = FakeFormatter(edits: [
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 2)), newText: "OK"),
            LSPTextEdit(range: LSPRange(start: LSPPosition(line: 3, character: 0), end: LSPPosition(line: 3, character: 1)), newText: "bad")
        ])
        try await buffer.formatAndSave(config: makeConfig(formatOnSave: true), lsp: formatter)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "HELLO")
        #expect(buffer.storage.string == "HELLO")
    }

    @Test func syncsCurrentTextBeforeFormatting() async throws {
        let root = tempWorktree()
        try writeFile(root, "a.txt", "hello")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        await buffer.awaitLoadForTesting()
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        let formatter = TrackingFormatter()
        try await buffer.formatAndSave(config: makeConfig(formatOnSave: true), lsp: formatter)
        #expect(formatter.didChangeCalls.first == "HELLO")
        #expect(formatter.didChangeCalls.last == "formatted")
    }
}

@MainActor
private final class FakeFormatter: DocumentFormatter, @unchecked Sendable {
    let edits: [LSPTextEdit]?
    let throwError: Bool
    let delayNanoseconds: UInt64
    private(set) var didChangeText: String?

    init(edits: [LSPTextEdit]? = nil, throwError: Bool = false, delayNanoseconds: UInt64 = 0) {
        self.edits = edits
        self.throwError = throwError
        self.delayNanoseconds = delayNanoseconds
    }

    func language(forFileExtension ext: String) -> String? {
        "swift"
    }

    func formatting(for fileURL: URL, languageId: String, options: LSPFormattingOptions) async -> [LSPTextEdit]? {
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if throwError { return nil }
        return edits
    }

    func didChange(worktreeRoot: URL, fileURL: URL, languageId: String, text: String, edits: [EditorTextEdit]?) async {
        didChangeText = text
    }
}

@MainActor
private final class TrackingFormatter: DocumentFormatter, @unchecked Sendable {
    private(set) var didChangeCalls: [String] = []

    func language(forFileExtension ext: String) -> String? {
        "swift"
    }

    func formatting(for fileURL: URL, languageId: String, options: LSPFormattingOptions) async -> [LSPTextEdit]? {
        [.init(range: .init(start: .init(line: 0, character: 0), end: .init(line: 0, character: 5)), newText: "formatted")]
    }

    func didChange(worktreeRoot: URL, fileURL: URL, languageId: String, text: String, edits: [EditorTextEdit]?) async {
        didChangeCalls.append(text)
    }
}
