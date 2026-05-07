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

    @Test func saveWritesContentAndClearsDirty() throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "hello\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        #expect(buffer.dirty == true)
        try buffer.save()
        #expect(buffer.dirty == false)
        let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
        #expect(onDisk == "HELLO\n")
        #expect(buffer.originalText == "HELLO\n")
    }

    @Test func saveCRLFFilePreservesCRLFOnDisk() throws {
        let root = tempWorktree()
        _ = try writeFile(root, "win.txt", "a\r\nb\r\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "win.txt")
        // In-memory storage is canonical LF; user appends a line.
        buffer.storage.replaceCharacters(in: NSRange(location: buffer.storage.length, length: 0), with: "c\n")
        try buffer.save()
        let onDisk = try Data(contentsOf: root.appendingPathComponent("win.txt"))
        #expect(onDisk == Data("a\r\nb\r\nc\r\n".utf8))
        #expect(buffer.dirty == false)
    }

    @Test func savePreservesPosixPermissions() throws {
        let root = tempWorktree()
        let url = try writeFile(root, "exe.sh", "#!/bin/sh\necho hi\n", perms: 0o755)
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "exe.sh")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# touched\n")
        try buffer.save()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o755)
    }

    @Test func saveOnReadOnlyDirThrowsAndKeepsBufferDirty() throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "x")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "more\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        }
        #expect(throws: (any Error).self) { try buffer.save() }
        #expect(buffer.dirty == true)
        #expect(buffer.originalText == "x")
    }

    @Test func saveUpdatesMtime() async throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "x")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        let oldMtime = buffer.originalMtime
        // Sleep a tiny bit so HFS/APFS-second-resolution mtimes actually advance.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "y")
        try buffer.save()
        #expect(buffer.originalMtime > oldMtime)
    }

    @Test func editingFlipsDirtyAndFiresObserver() async {
        let root = tempWorktree()
        _ = try? writeFile(root, "a.txt", "hello\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        var fired = 0
        let token = buffer.onEdit { fired += 1 }
        defer { buffer.removeOnEdit(token) }
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "HELLO")
        #expect(buffer.dirty == true)
        #expect(fired == 1)
    }

    @Test func revertReloadsFromDiskAndClearsDirty() throws {
        let root = tempWorktree()
        _ = try writeFile(root, "a.txt", "original\n")
        let buffer = EditorBuffer(worktreeRoot: root, relativePath: "a.txt")
        buffer.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "junk")
        #expect(buffer.dirty == true)
        buffer.revert()
        #expect(buffer.storage.string == "original\n")
        #expect(buffer.dirty == false)
    }
}
