import Foundation
import Testing
@testable import Alas

struct PluginManifestTests {
    @Test func parsesAValidManifestIgnoringUnknownFields() throws {
        let json = #"{"id":"io.nlopez.hello","name":"Hello","version":"0.1.0","api":1,"entry":"plugin.wasm","capabilities":["workspace.read"],"future":{"x":1}}"#
        let manifest = try PluginManifest.parse(Data(json.utf8))
        #expect(manifest == PluginManifest(
            id: "io.nlopez.hello", name: "Hello", version: "0.1.0", api: 1,
            entry: "plugin.wasm", capabilities: [.workspaceRead]))
    }

    @Test(arguments: [
        ("{", PluginManifestError.malformed),
        (#"{"name":"H","version":"1","api":1,"entry":"p.wasm"}"#, .missingField("id")),
        (#"{"id":"io.x.h","name":" ","version":"1","api":1,"entry":"p.wasm"}"#, .missingField("name")),
        (#"{"id":"io.x.h","name":"H","version":"\n\t ","api":1,"entry":"p.wasm"}"#, .missingField("version")),
        (#"{"id":"Hello","name":"H","version":"1","api":1,"entry":"p.wasm"}"#, .invalidID("Hello")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm"}"#, .unsupportedAPI(2)),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm","capabilities":["network"]}"#, .unknownCapability("network")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm","capabilities":null}"#, .malformed),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"../p.wasm"}"#, .invalidEntry("../p.wasm")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"/tmp/p.wasm"}"#, .invalidEntry("/tmp/p.wasm")),
    ])
    func rejectsInvalidManifests(json: String, expected: PluginManifestError) {
        #expect(throws: expected) { try PluginManifest.parse(Data(json.utf8)) }
    }

    @Test func unsupportedAPIMessageNamesBothVersions() {
        #expect(PluginManifestError.unsupportedAPI(2).description == "requires plugin API 2; this Alas supports 1")
    }
}
