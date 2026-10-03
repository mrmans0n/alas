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

private func prompts(_ list: String) -> String { #","contributes":{"prompts":[\#(list)]}"# }

private func network(_ hosts: String) -> String { #","capabilities":["network"],"network":[\#(hosts)]"# }

private func processes(_ list: String) -> String { #","capabilities":["process.exec"],"processes":[\#(list)]"# }

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
        (manifest(api: 11), .unsupportedAPI(11)),
        (manifest(api: 8, panels(#"{"id":"c","title":"C","location":"configure"}"#)), .needsNewerAPI(#"panel "c" location "configure""#, api: 9)),
        (manifest(api: 9, panels(#"{"id":"c","title":"C","location":"configure"},{"id":"d","title":"D","location":"configure"}"#)),
         .invalidPanel(#"at most one panel with location "configure""#)),
        (manifest(api: 7, #","contributes":{"tabs":[{"id":"t","title":"T"}],"commands":[{"id":"a","title":"A","slots":["palette"],"opens":"t"}]}"#),
         .needsNewerAPI(#"command "a" "opens""#, api: 8)),
        (manifest(api: 8, #","contributes":{"tabs":[{"id":"t","title":"T"}],"commands":[{"id":"a","title":"A","slots":["palette"],"opens":"u"}]}"#),
         .invalidCommand(#"command "a" opens "u", which is not a declared tab"#)),
        (manifest(api: 6, #","capabilities":["session.context"]"#), .needsNewerAPI(#"capability "session.context""#, api: 7)),
        (manifest(api: 6, prompts(#"{"name":"a"}"#)), .needsNewerAPI(#""contributes.prompts""#, api: 7)),
        (manifest(api: 7, prompts(#"{"name":"Fix it"}"#)), .invalidPrompt(#"invalid prompt name "Fix it""#)),
        (manifest(api: 7, prompts(#"{"name":"a"},{"name":"a"}"#)), .invalidPrompt(#"duplicate prompt name "a""#)),
        (manifest(api: 7, prompts(#"{"name":"a","description":"\#(String(repeating: "x", count: 201))"}"#)), .invalidPrompt(#"prompt "a" has a description longer than 200 characters"#)),
        (manifest(api: 7, prompts((0...16).map { #"{"name":"p\#($0)"}"# }.joined(separator: ","))), .invalidPrompt("at most 16 prompts")),
        (manifest(api: 4, commands(#"{"id":"a","title":"A","slots":["palette"]}"#)), .needsNewerAPI(#""contributes.commands""#)),
        (manifest(api: 4, #","capabilities":["notify"]"#), .needsNewerAPI(#"capability "notify""#)),
        (manifest(api: 4, #","capabilities":["session.read"],"events":["session.finished"]"#), .needsNewerAPI(#""events""#)),
        (manifest(#","capabilities":["session.read"],"events":["nope.x"]"#), .unknownEvent("nope.x")),
        (manifest(#","capabilities":["workspace.read"],"events":["git.changed"]"#), .needsNewerAPI(#"event "git.changed""#, api: 6)),
        (manifest(#","capabilities":["runs.read"]"#), .needsNewerAPI(#"capability "runs.read""#, api: 6)),
        (manifest(api: 6, #","capabilities":["workspace.read"],"events":["run.finished"]"#), .eventNeedsCapability("run.finished")),
        (manifest(api: 6, panels((0...4).map { #"{"id":"p\#($0)","title":"P"}"# }.joined(separator: ","))), .invalidPanel("at most 4 panels")),
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
        (#"{"id":"io.x.h","name":"H","version":"1","api":4,"entry":"p.js","capabilities":["files.delete"]}"#, .unknownCapability("files.delete")),
        (manifest(api: 4, #","capabilities":["files.write"]"#), .needsNewerAPI(#"capability "files.write""#, api: 6)),
        (manifest(#","processes":[{"id":"a","command":["ls"]}]"#), .needsNewerAPI(#""processes""#, api: 6)),
        (manifest(api: 6, #","processes":[{"id":"a","command":["ls"]}]"#), .invalidProcess(#""processes" needs capability "process.exec""#)),
        (manifest(api: 6, #","capabilities":["process.exec"]"#), .invalidProcess(#"capability "process.exec" needs at least one process"#)),
        (manifest(api: 6, processes(#"{"id":"a","command":[]}"#)), .invalidProcess(#"process "a" needs a command"#)),
        (manifest(api: 6, processes(#"{"id":"a","command":["ls","\#(String(repeating: "x", count: 1025))"]}"#)), .invalidProcess(#"process "a" has an argument longer than 1024 bytes"#)),
        (manifest(api: 6, processes(#"{"id":"a","command":["ls"]},{"id":"a","command":["pwd"]}"#)), .invalidProcess(#"duplicate process id "a""#)),
        (manifest(api: 6, processes(#"{"id":"A!","command":["ls"]}"#)), .invalidProcess(#"invalid process id "A!""#)),
        (manifest(api: 6, processes((0...16).map { #"{"id":"p\#($0)","command":["ls"]}"# }.joined(separator: ","))), .invalidProcess("at most 16 processes")),
        (manifest(api: 4, panels(#"{"id":"p","title":"P"}"#)), .needsNewerAPI(#""contributes.panels""#)),
        (manifest(panels(#"{"id":"P!","title":"P"}"#)), .invalidPanel(#"invalid panel id "P!""#)),
        (manifest(panels(#"{"id":"p","title":"P"},{"id":"p","title":"Q"}"#)), .invalidPanel(#"duplicate panel id "p""#)),
        (manifest(panels(#"{"id":"p","title":"P","location":"sidebar"},{"id":"p","title":"Q"}"#)), .invalidPanel(#"duplicate panel id "p""#)),
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
        (manifest(settings(#"{"key":"token","title":"A","type":"string"},{"key":"Token","title":"B","type":"string"}"#)), .invalidSetting(#"duplicate setting key "Token""#)),
        (manifest(settings(#"{"key":"a","title":"A","type":"string","default":"\#(String(repeating: "x", count: 4097))"}"#)), .invalidSetting(#"setting "a" has a default longer than 4096 bytes"#)),
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

    /// Unknown slots, and slots newer than the manifest's API, are skipped rather than refused, because slots keep growing.
    @Test(arguments: [
        (5, [PluginCommandSlot.worktreeMenu]), (6, [.worktreeMenu, .changesToolbar]), (7, [.worktreeMenu, .changesToolbar, .messageMenu]),
    ])
    func commandsKeepKnownSlotsAndEventsNeedTheirCapability(api: Int, slots: [PluginCommandSlot]) throws {
        let parsed = try PluginManifest.parse(Data(manifest(api: api,
            #","capabilities":["session.read","notify"],"events":["session.finished"],"contributes":{"commands":[{"id":"fix","title":"Fix","icon":"wrench","slots":["worktree.menu","changes.toolbar","message.menu","nope"]}]}"#).utf8))
        #expect(parsed.commands == [PluginCommandContribution(id: "fix", title: "Fix", icon: "wrench", slots: slots)])
        #expect(parsed.events == [.sessionFinished])
    }

    @Test func commandsKeepTheTabTheyOpen() throws {
        let parsed = try PluginManifest.parse(Data(manifest(api: 8,
            #","contributes":{"tabs":[{"id":"inbox","title":"Inbox","kind":"view"}],"commands":[{"id":"a","title":"A","slots":["palette"],"opens":"inbox"}]}"#).utf8))
        #expect(parsed.commands.first?.opens == "inbox")
    }

    /// Locations newer than the manifest's API are skipped like unknown command slots; the icon defaults.
    @Test(arguments: [(5, ["a"]), (6, ["a", "b"])])
    func panelsDefaultTheirIconAndSkipUnknownLocations(api: Int, ids: [String]) throws {
        let parsed = try PluginManifest.parse(Data(manifest(api: api, panels(
            #"{"id":"a","title":"A","location":"right"},{"id":"b","title":"B","icon":"checklist","location":"changes.section"}"#)).utf8))
        #expect(parsed.panels.map(\.id) == ids)
        #expect(parsed.panels.first == PluginPanelContribution(id: "a", title: "A"))
        #expect(parsed.panels.dropFirst().allSatisfy { $0.location == .changesSection && $0.icon == "checklist" })
    }

    @Test func aConfigurePanelIsKeptBesideTheOthers() throws {
        let parsed = try PluginManifest.parse(Data(manifest(api: 9, panels(
            #"{"id":"a","title":"A"},{"id":"c","title":"Setup","location":"configure"}"#)).utf8))
        #expect(parsed.configurePanel == PluginPanelContribution(id: "c", title: "Setup", location: .configure))
        #expect(parsed.panels.count == 2)
    }

    @Test func processesKeepTheirArgvAndFlags() throws {
        let parsed = try PluginManifest.parse(Data(manifest(api: 6, processes(
            #"{"id":"install","command":["pnpm","install"]},{"id":"dev","command":["pnpm","dev"],"appendArgs":true,"longRunning":true}"#)).utf8))
        #expect(parsed.processes == [
            PluginProcessContribution(id: "install", command: ["pnpm", "install"]),
            PluginProcessContribution(id: "dev", command: ["pnpm", "dev"], appendArgs: true, longRunning: true),
        ])
    }

    @Test func promptsKeepTheirNameAndOptionalDescription() throws {
        let parsed = try PluginManifest.parse(Data(manifest(api: 7, prompts(#"{"name":"linear","description":" Issue "},{"name":"todo","description":""}"#)).utf8))
        #expect(parsed.prompts == [
            PluginPromptContribution(name: "linear", description: "Issue"), PluginPromptContribution(name: "todo"),
        ])
    }

    @Test func eventNeedsCapabilityNamesTheEventsOwnCapability() {
        #expect(PluginManifestError.eventNeedsCapability("review.changed").description
            == #"event "review.changed" needs capability "review.read""#)
    }

    @Test(arguments: [
        (2, "built for plugin API 2, the WebAssembly runtime, which Alas no longer supports; rebuild it for API 10"),
        (11, "requires plugin API 11; this Alas supports up to 10"),
    ])
    func unsupportedAPIMessageSaysWhatToDo(api: Int, message: String) {
        #expect(PluginManifestError.unsupportedAPI(api).description == message)
    }
}
