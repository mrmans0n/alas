import Foundation
import Testing
@testable import Alas

struct PluginManagerDiscoveryTests {
    @Test func invalidAndDuplicateFoldersAreReportedAndNotLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func install(_ folder: String, id: String, wasm: Bool = true, entry: String = "plugin.wasm") throws {
            let dir = root.appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"id":"\#(id)","name":"N","version":"1","api":1,"entry":"\#(entry)"}"#.utf8)
                .write(to: dir.appending(path: "plugin.json"))
            if wasm { try Data([0]).write(to: dir.appending(path: "plugin.wasm")) }
        }
        try install("good", id: "io.x.good")
        try install("no-wasm", id: "io.x.nowasm", wasm: false)
        try install("dup-a", id: "io.x.dup")
        try install("dup-b", id: "io.x.dup")
        // An entry symlinked to a file outside its folder escapes the folder.
        try install("linked-out", id: "io.x.linkedout", wasm: false)
        let outside = root.appending(path: "outside.wasm")
        try Data([0]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked-out/plugin.wasm"), withDestinationURL: outside)
        // So does an entry that reaches its file through a symlinked directory.
        try install("linked-dir", id: "io.x.linkeddir", wasm: false, entry: "link/plugin.wasm")
        let outsideDir = FileManager.default.temporaryDirectory.appending(path: "PluginDiscoveryOutside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try Data([0]).write(to: outsideDir.appending(path: "plugin.wasm"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "linked-dir/link"), withDestinationURL: outsideDir)

        let result = PluginManager.discover(in: root)

        #expect(result.plugins.map(\.id) == ["io.x.good"])
        #expect(Set(result.invalid.map(\.folder.lastPathComponent)) == ["no-wasm", "dup-a", "dup-b", "linked-out", "linked-dir"])
    }
}
