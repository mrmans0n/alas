import Foundation
import Testing
@testable import Alas

struct PluginManagerDiscoveryTests {
    @Test func invalidAndDuplicateFoldersAreReportedAndNotLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PluginDiscovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func install(_ folder: String, id: String, wasm: Bool = true) throws {
            let dir = root.appending(path: folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"{"id":"\#(id)","name":"N","version":"1","api":1,"entry":"plugin.wasm"}"#.utf8)
                .write(to: dir.appending(path: "plugin.json"))
            if wasm { try Data([0]).write(to: dir.appending(path: "plugin.wasm")) }
        }
        try install("good", id: "io.x.good")
        try install("no-wasm", id: "io.x.nowasm", wasm: false)
        try install("dup-a", id: "io.x.dup")
        try install("dup-b", id: "io.x.dup")

        let result = PluginManager.discover(in: root)

        #expect(result.plugins.map(\.id) == ["io.x.good"])
        #expect(Set(result.invalid.map(\.folder.lastPathComponent)) == ["no-wasm", "dup-a", "dup-b"])
    }
}
