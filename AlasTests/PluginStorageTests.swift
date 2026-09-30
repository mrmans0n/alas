import Foundation
import Testing
@testable import Alas

@MainActor
struct PluginStorageTests {
    private func makeFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "PluginStorage-\(UUID().uuidString)/io.x.p/proj.json")
    }

    @Test func valuesRoundTripThroughTheFileAndNullDeletes() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = PluginStorage(file: file)
        #expect(storage.set("board", value: Data(#"{"cards":[1,2]}"#.utf8)) == .stored)
        #expect(storage.set("other", value: Data("3".utf8)) == .stored)
        #expect(storage.set("other", value: nil) == .stored)

        let reopened = PluginStorage(file: file)
        #expect(reopened.keys() == ["board"])
        let value = try #require(reopened.get("board"))
        #expect(try JSONSerialization.jsonObject(with: value) as? [String: [Int]] == ["cards": [1, 2]])
        #expect(reopened.get("other") == nil)
    }

    @Test func rawValueBytesSurviveReloadUnchanged() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = PluginStorage(file: file)
        let raw = Data(#"{"a":1.0,"big":12345678901234567890,"s":"x,}\"y"}"#.utf8)
        #expect(storage.set("k\"/", value: raw) == .stored)
        #expect(PluginStorage(file: file).get("k\"/") == raw)
    }

    @Test func aWriteOverTheLimitChangesNothing() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = PluginStorage(file: file)
        #expect(storage.set("a", value: Data("1".utf8)) == .stored)
        let before = try Data(contentsOf: file)
        let huge = Data(("\"" + String(repeating: "x", count: PluginStorage.maxTotalBytes) + "\"").utf8)
        #expect(storage.set("b", value: huge) == .full)
        #expect(try Data(contentsOf: file) == before)
        #expect(storage.keys() == ["a"])
    }

    @Test(arguments: ["", String(repeating: "k", count: 129)])
    func invalidKeysAreRejected(key: String) {
        #expect(PluginStorage(file: makeFile()).set(key, value: Data("1".utf8)) == .invalidKey)
    }

    @Test(arguments: ["..", ".", "a/b", "../../x", ""])
    func projectIDsCannotEscapeThePluginFolder(projectID: String) {
        let root = URL(filePath: "/tmp/root")
        let file = PluginStorage.file(pluginID: "io.x.p", projectID: projectID, root: root)
        #expect(file.deletingLastPathComponent().path == "/tmp/root/PluginData/io.x.p")
        #expect(file.lastPathComponent.hasSuffix(".json"))
    }

    @Test(arguments: [
        Data("{oops".utf8),
        "1".data(using: .utf16)!,
        Data([0xEF, 0xBB, 0xBF]) + Data("1".utf8),
    ])
    func invalidValuesAreRejectedAndLeaveTheFileUntouched(value: Data) throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let storage = PluginStorage(file: file)
        #expect(storage.set("a", value: Data("1".utf8)) == .stored)
        let before = try Data(contentsOf: file)
        #expect(storage.set("b", value: value) == .invalidValue)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func anUnreadableFileIsMovedAsideBeforeTheFirstWrite() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("not json".utf8)
        try garbage.write(to: file)
        let storage = PluginStorage(file: file)
        #expect(storage.keys().isEmpty)
        #expect(storage.set("new", value: Data("1".utf8)) == .stored)
        #expect(try Data(contentsOf: file.appendingPathExtension("corrupt")) == garbage)
        #expect(PluginStorage(file: file).keys() == ["new"])
    }

    @Test func anUnreadableFileThatCannotBeMovedAsideStaysIntactAndBlocksWrites() throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent().deletingLastPathComponent()) }
        let aside = file.appendingPathExtension("corrupt")
        // A non-empty directory at the .corrupt path makes replacing it impossible.
        try FileManager.default.createDirectory(
            at: aside.appending(path: "d"), withIntermediateDirectories: true)
        let marker = aside.appending(path: "d/keep")
        try Data("old".utf8).write(to: marker)
        let garbage = Data("not json".utf8)
        try garbage.write(to: file)
        let storage = PluginStorage(file: file)
        #expect(storage.set("new", value: Data("1".utf8)) == .failed)
        #expect(storage.keys().isEmpty)
        #expect(try Data(contentsOf: file) == garbage)
        #expect(try Data(contentsOf: marker) == Data("old".utf8))
    }
}
