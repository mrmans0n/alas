import AppKit
import Foundation
import Testing
@testable import Alas

@MainActor
struct EditorBufferExternalEditableTests {
    private func makeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-editable-\(UUID().uuidString).sh")
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    @Test func externalBufferIsReadOnlyByDefault() throws {
        let url = try makeTempFile(contents: "echo hi\n")
        let buffer = EditorBuffer(externalAbsoluteURL: url)
        #expect(buffer.readOnly)
        #expect(!buffer.externalEditable)
    }

    @Test func editableExternalBufferSavesToDisk() throws {
        let url = try makeTempFile(contents: "echo hi\n")
        let buffer = EditorBuffer(externalAbsoluteURL: url, editable: true)
        #expect(!buffer.readOnly)
        buffer.storage.replaceCharacters(
            in: NSRange(location: 0, length: buffer.storage.length),
            with: "echo bye\n"
        )
        #expect(buffer.dirty)
        try buffer.save()
        #expect(try String(contentsOf: url, encoding: .utf8) == "echo bye\n")
        #expect(!buffer.dirty)
    }

    @Test func editableExternalBufferNotifiesDirtyStateObservers() throws {
        let url = try makeTempFile(contents: "echo hi\n")
        let buffer = EditorBuffer(externalAbsoluteURL: url, editable: true)
        var notifications = 0
        let token = buffer.onEdit { notifications += 1 }
        defer { buffer.removeOnEdit(token) }

        let generation = buffer.editGeneration
        buffer.storage.replaceCharacters(
            in: NSRange(location: 0, length: buffer.storage.length),
            with: "echo bye\n"
        )

        #expect(buffer.editGeneration == generation + 1)
        #expect(notifications == 1)
        #expect(buffer.dirty)
    }

    /// Regression test for the Task-9 critical fix: `CodeEditorCoordinator`
    /// computes `textView.isEditable` as `!buffer.isExternal || !buffer.readOnly`
    /// so that non-external buffers (e.g. remote in-worktree files whose
    /// `readOnly` is transiently `true` while loading) stay editable
    /// regardless of `readOnly`, while external read-only buffers stay
    /// locked. A missing on-disk file is a simple, synchronous way to drive
    /// a non-external buffer into `readOnly == true`.
    @Test func nonExternalReadOnlyBufferStillSatisfiesCoordinatorEditableInvariant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-external-editable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let nonExternalReadOnlyBuffer = EditorBuffer(worktreeRoot: root, relativePath: "missing.txt")
        await nonExternalReadOnlyBuffer.awaitLoadForTesting()
        #expect(nonExternalReadOnlyBuffer.isExternal == false)
        #expect(nonExternalReadOnlyBuffer.readOnly == true)
        #expect((!nonExternalReadOnlyBuffer.isExternal || !nonExternalReadOnlyBuffer.readOnly) == true)

        let url = try makeTempFile(contents: "echo hi\n")
        let externalReadOnlyBuffer = EditorBuffer(externalAbsoluteURL: url)
        #expect(externalReadOnlyBuffer.isExternal == true)
        #expect(externalReadOnlyBuffer.readOnly == true)
        #expect((!externalReadOnlyBuffer.isExternal || !externalReadOnlyBuffer.readOnly) == false)
    }
}
