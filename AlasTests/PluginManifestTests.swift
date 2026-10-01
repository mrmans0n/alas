import Foundation
import Testing
@testable import Alas

/// A minimal manifest with `extra` spliced in after `entry`. File scope so `@Test(arguments:)` can call it.
private func manifest(api: Int = 5, _ extra: String = "") -> String {
    #"{"id":"io.x.h","name":"H","version":"1","api":\#(api),"entry":"p.js"\#(extra)}"#
}

private func commands(_ list: String) -> String { #","contributes":{"commands":[\#(list)]}"# }

private func panels(_ list: String, tabs: String = "") -> String {
    #","contributes":{"tabs":[\#(tabs)],"panels":[\#(list)]}"#
}

private func network(_ hosts: String) -> String { #","capabilities":["network"],"network":[\#(hosts)]"# }

private func settings(_ list: String) -> String { network(#""a.com""#) + #","settings":[\#(list)]"# }

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
        (manifest(api: 6), .unsupportedAPI(6)),
        (manifest(api: 4, commands(#"{"id":"a","title":"A","slots":["palette"]}"#)), .needsNewerAPI(#""contributes.commands""#)),
        (manifest(api: 4, #","capabilities":["notify"]"#), .needsNewerAPI(#"capability "notify""#)),
        (manifest(api: 4, #","capabilities":["session.read"],"events":["session.finished"]"#), .needsNewerAPI(#""events""#)),
        (manifest(#","capabilities":["session.read"],"events":["git.changed"]"#), .unknownEvent("git.changed")),
        (manifest(#","events":["session.state"]"#), .eventNeedsCapability("session.state")),
        (manifest(commands(#"{"id":"A!","title":"A","slots":["palette"]}"#)), .invalidCommand(#"invalid command id "A!""#)),
        (manifest(commands(#"{"id":"a","title":"A","slots":["palette"]},{"id":"a","title":"B","slots":["palette"]}"#)), .invalidCommand(#"duplicate command id "a""#)),
        (manifest(commands(#"{"id":"a","title":"","slots":["palette"]}"#)), .invalidCommand(#"command "a" needs a title of 1 to 40 characters"#)),
        (manifest(commands(#"{"id":"a","title":"A","slots":[]}"#)), .invalidCommand(#"command "a" needs at least one slot"#)),
        (manifest(commands((0...16).map { #"{"id":"c\#($0)","title":"C","slots":["palette"]}"# }.joined(separator: ","))), .invalidCommand("at most 16 commands")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"a","title":"A","kind":"table"}]}}"#, .invalidTab("tab \"a\" has unknown kind \"table\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"a","title":"A"},{"id":"a","title":"B"}]}}"#, .invalidTab("duplicate tab id \"a\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"a","title":" "}]}}"#, .invalidTab("tab \"a\" needs a title of 1 to 40 characters")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"A!","title":"T"}]}}"#, .invalidTab("invalid tab id \"A!\"")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"a","title":"T"},{"id":"b","title":"T"},{"id":"c","title":"T"},{"id":"d","title":"T"},{"id":"e","title":"T"}]}}"#, .invalidTab("at most 4 tabs")),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","contributes":5}"#, .malformed),
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","capabilities":["files.write"]}"#, .unknownCapability("files.write")),
        (manifest(api: 4, panels(#"{"id":"p","title":"P"}"#)), .needsNewerAPI(#""contributes.panels""#)),
        (manifest(panels(#"{"id":"P!","title":"P"}"#)), .invalidPanel(#"invalid panel id "P!""#)),
        (manifest(panels(#"{"id":"p","title":"P"},{"id":"p","title":"Q"}"#)), .invalidPanel(#"duplicate panel id "p""#)),
        (manifest(panels(#"{"id":"p","title":"P"}"#, tabs: #"{"id":"p","title":"T","kind":"view"}"#)), .invalidPanel(#"panel id "p" is also a tab id"#)),
        (manifest(panels(#"{"id":"p","title":"\#(String(repeating: "x", count: 41))"}"#)), .invalidPanel(#"panel "p" needs a title of 1 to 40 characters"#)),
        (manifest(panels(#"{"id":"a","title":"A"},{"id":"b","title":"B"},{"id":"c","title":"C"}"#)), .invalidPanel("at most 2 panels")),
        (manifest(api: 4, #","settings":[]"#), .needsNewerAPI(#""settings""#)),
        (manifest(#","capabilities":["network"]"#), .invalidNetwork(#"capability "network" needs at least one host"#)),
        (manifest(#","network":["a.com"]"#), .invalidNetwork(#""network" needs capability "network""#)),
        (manifest(network(#""https://a.com""#)), .invalidNetwork(#""https://a.com" is not a lowercase hostname; no schemes, ports or wildcards"#)),
        (manifest(network(#""*.a.com""#)), .invalidNetwork(#""*.a.com" is not a lowercase hostname; no schemes, ports or wildcards"#)),
        (manifest(network(#""a.com:443""#)), .invalidNetwork(#""a.com:443" is not a lowercase hostname; no schemes, ports or wildcards"#)),
        (manifest(settings(#"{"key":"a b","title":"A","type":"string"}"#)), .invalidSetting(#"invalid setting key "a b""#)),
        (manifest(settings(#"{"key":"a","title":"A","type":"number"}"#)), .invalidSetting(#"setting "a" has unknown type "number""#)),
        (manifest(settings(#"{"key":"a","title":"A","type":"bool","default":"yes"}"#)), .invalidSetting(#"setting "a" has a default of the wrong type"#)),
        (manifest(settings(#"{"key":"a","title":"A","type":"secret"}"#)), .invalidSetting(#"secret "a" needs at least one host"#)),
        (manifest(settings(#"{"key":"a","title":"A","type":"secret","hosts":["b.com"]}"#)), .invalidSetting(#"secret "a" names "b.com", which is not in "network""#)),
        (manifest(settings(#"{"key":"a","title":"A","type":"string","hosts":["a.com"]}"#)), .invalidSetting("only secret settings take hosts")),
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

    /// Unknown slots are skipped rather than refused, because slots keep growing.
    @Test func commandsKeepKnownSlotsAndEventsNeedTheirCapability() throws {
        let parsed = try PluginManifest.parse(Data(manifest(
            #","capabilities":["session.read","notify"],"events":["session.finished"],"contributes":{"commands":[{"id":"fix","title":"Fix","icon":"wrench","slots":["worktree.menu","changes.toolbar"]}]}"#).utf8))
        #expect(parsed.commands == [PluginCommandContribution(id: "fix", title: "Fix", icon: "wrench", slots: [.worktreeMenu])])
        #expect(parsed.events == [.sessionFinished])
    }

    /// Unknown locations are skipped like unknown command slots; the icon defaults.
    @Test func panelsDefaultTheirIconAndSkipUnknownLocations() throws {
        let parsed = try PluginManifest.parse(Data(manifest(panels(
            #"{"id":"a","title":"A","location":"right"},{"id":"b","title":"B","icon":"checklist","location":"changes.section"}"#)).utf8))
        #expect(parsed.panels == [PluginPanelContribution(id: "a", title: "A")])
    }

    @Test(arguments: [
        (2, "built for plugin API 2, the WebAssembly runtime, which Alas no longer supports; rebuild it for API 5"),
        (6, "requires plugin API 6; this Alas supports up to 5"),
    ])
    func unsupportedAPIMessageSaysWhatToDo(api: Int, message: String) {
        #expect(PluginManifestError.unsupportedAPI(api).description == message)
    }
}
