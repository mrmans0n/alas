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
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.wasm"}"#, .unsupportedAPI(4)),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":"A","kind":"view"}]}}"#, .invalidTab("tab \"a\" sets kind, which requires plugin API 3")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":3,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":"A","kind":"table"}]}}"#, .invalidTab("tab \"a\" has unknown kind \"table\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","capabilities":["tasks.start"]}"#, .capabilityNeedsNewerAPI("tasks.start", 3)),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm","capabilities":["session.focus"]}"#, .capabilityNeedsNewerAPI("session.focus", 2)),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}}"#, .invalidTab("duplicate tab id \"a\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":" "}]}}"#, .invalidTab("tab \"a\" needs a title of 1 to 40 characters")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"A!","title":"T"}]}}"#, .invalidTab("invalid tab id \"A!\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"a","title":"T"},{"id":"b","title":"T"},{"id":"c","title":"T"},{"id":"d","title":"T"},{"id":"e","title":"T"}]}}"#, .invalidTab("at most 4 tabs")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","contributes":5}"#, .malformed),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm","capabilities":["network"]}"#, .unknownCapability("network")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm","capabilities":null}"#, .malformed),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"../p.wasm"}"#, .invalidEntry("../p.wasm")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"/tmp/p.wasm"}"#, .invalidEntry("/tmp/p.wasm")),
    ])
    func rejectsInvalidManifests(json: String, expected: PluginManifestError) {
        #expect(throws: expected) { try PluginManifest.parse(Data(json.utf8)) }
    }

    @Test func apiThreeTabsDeclareTheirKindAndDefaultToCanvas() throws {
        let manifest = try PluginManifest.parse(Data(#"{"id":"io.x.h","name":"H","version":"1","api":3,"entry":"p.wasm","capabilities":["tasks.start"],"contributes":{"tabs":[{"id":"a","title":"A","kind":"view"},{"id":"b","title":"B"}]}}"#.utf8))
        #expect(manifest.tabs.map(\.kind) == [.view, .canvas])
        #expect(manifest.capabilities == [.tasksStart])
    }

    @Test func unsupportedAPIMessageNamesBothVersions() {
        #expect(PluginManifestError.unsupportedAPI(4).description == "requires plugin API 4; this Alas supports 1, 2, 3")
    }

    @Test func apiTwoManifestsDeclareTabsAndApiOneManifestsIgnoreThem() throws {
        let tabs = #""contributes":{"tabs":[{"id":"office","title":"Office"}]}"#
        let v2 = try PluginManifest.parse(Data(#"{"id":"io.x.h","name":"H","version":"1","api":2,"entry":"p.wasm","capabilities":["session.focus"],\#(tabs)}"#.utf8))
        #expect(v2.tabs == [PluginTabContribution(id: "office", title: "Office")])
        #expect(v2.capabilities == [.sessionFocus])
        let v1 = try PluginManifest.parse(Data(#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm",\#(tabs)}"#.utf8))
        #expect(v1.tabs.isEmpty)
        let v1Junk = try PluginManifest.parse(Data(#"{"id":"io.x.h","name":"H","version":"1","api":1,"entry":"p.wasm","contributes":5}"#.utf8))
        #expect(v1Junk.tabs.isEmpty)
    }
}
