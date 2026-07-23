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
}
