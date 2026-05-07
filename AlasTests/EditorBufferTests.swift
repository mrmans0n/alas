// AlasTests/EditorBufferTests.swift
import Testing
import Foundation
import AppKit
@testable import Alas

@MainActor
@Suite(.serialized)
struct EditorBufferTests {
    private func tempWorktree() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-buffer-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ root: URL, _ rel: String, _ contents: String, perms: Int = 0o644) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
        return url
    }

    @Test func coldLoadCapturesContentMtimeAndPerms() throws {
        let root = tempWorktree()
        let url = try writeFile(root, "a.txt", "hello\nworld\n", perms: 0o644)
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        #expect(buffer.storage.string == "hello\nworld\n")
        #expect(buffer.originalText == "hello\nworld\n")
        #expect(buffer.lineEnding == .lf)
        #expect(buffer.dirty == false)
        #expect(buffer.permissions == 0o644)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let onDisk = attrs[.modificationDate] as? Date
        #expect(buffer.originalMtime == onDisk)
    }

    @Test func coldLoadDetectsCRLF() throws {
        let root = tempWorktree()
        _ = try writeFile(root, "win.txt", "a\r\nb\r\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "win.txt")
        #expect(buffer.lineEnding == .crlf)
        // We canonicalize to LF in memory; save normalizes back.
        #expect(buffer.storage.string == "a\nb\n")
        #expect(buffer.originalText == "a\nb\n")
    }

    @Test func coldLoadOnMissingFileReadsAsErrorAndIsReadOnly() {
        let root = tempWorktree()
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "missing.txt")
        #expect(buffer.storage.string == "(unable to read file)")
        #expect(buffer.readOnly == true)
        #expect(buffer.dirty == false)
    }
}
