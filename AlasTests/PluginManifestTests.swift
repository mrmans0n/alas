import Foundation
import Testing
@testable import Alas

struct PluginManifestTests {
    @Test func parsesAValidManifestIgnoringUnknownFields() throws {
        let json = #"{"id":"io.nlopez.hello","name":"Hello","version":"0.1.0","api":4,"entry":"plugin.js","capabilities":["workspace.read"],"future":{"x":1}}"#
        let manifest = try PluginManifest.parse(Data(json.utf8))
        #expect(manifest == PluginManifest(
            id: "io.nlopez.hello", name: "Hello", version: "0.1.0", api: 4,
            entry: "plugin.js", capabilities: [.workspaceRead]))
    }

    @Test(arguments: [
        ("{", PluginManifestError.malformed),
        (#"{"name":"H","version":"1","api":4,"entry":"p.js"}"#, .missingField("id")),
        (#"{"id":"io.x.h","name":" ","version":"1","api":4,"entry":"p.js"}"#, .missingField("name")),
        (#"{"id":"io.x.h","name":"H","version":"\n\t ","api":4,"entry":"p.js"}"#, .missingField("version")),
        (#"{"id":"Hello","name":"H","version":"1","api":4,"entry":"p.js"}"#, .invalidID("Hello")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":5,"entry":"p.js"}"#, .unsupportedAPI(5)),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"a","title":"A","kind":"table"}]}}"#, .invalidTab("tab \"a\" has unknown kind \"table\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}}"#, .invalidTab("duplicate tab id \"a\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"a","title":" "}]}}"#, .invalidTab("tab \"a\" needs a title of 1 to 40 characters")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"A!","title":"T"}]}}"#, .invalidTab("invalid tab id \"A!\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"a","title":"T"},{"id":"b","title":"T"},{"id":"c","title":"T"},{"id":"d","title":"T"},{"id":"e","title":"T"}]}}"#, .invalidTab("at most 4 tabs")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":5}"#, .malformed),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","capabilities":["network"]}"#, .unknownCapability("network")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","capabilities":null}"#, .malformed),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"../p.js"}"#, .invalidEntry("../p.js")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"/tmp/p.js"}"#, .invalidEntry("/tmp/p.js")),
    ])
    func rejectsInvalidManifests(json: String, expected: PluginManifestError) {
        #expect(throws: expected) { try PluginManifest.parse(Data(json.utf8)) }
    }

    @Test func tabsDeclareTheirKindAndDefaultToCanvas() throws {
        let manifest = try PluginManifest.parse(Data(#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","capabilities":["tasks.start"],"contributes":{"tabs":[{"id":"a","title":"A","kind":"view"},{"id":"b","title":"B"}]}}"#.utf8))
        #expect(manifest.tabs.map(\.kind) == [.view, .canvas])
        #expect(manifest.capabilities == [.tasksStart])
    }

    @Test(arguments: [
        (2, "built for plugin API 2, the WebAssembly runtime, which Alas no longer supports; rebuild it for API 4"),
        (5, "requires plugin API 5; this Alas supports 4"),
    ])
    func unsupportedAPIMessageSaysWhatToDo(api: Int, message: String) {
        #expect(PluginManifestError.unsupportedAPI(api).description == message)
    }
}
