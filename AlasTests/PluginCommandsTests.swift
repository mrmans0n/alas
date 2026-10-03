import Foundation
import Testing
@testable import Alas

struct PluginCommandsTests {
    private static func plugin(_ id: String, _ commands: [(String, [PluginCommandSlot])]) -> PluginManifest {
        PluginManifest(
            id: id, name: id, version: "1", api: 5, entry: "p.js", capabilities: [],
            commands: commands.map { PluginCommandContribution(id: $0.0, title: $0.0, slots: $0.1) })
    }

    /// Only running plugins contribute, each command only to the slots it names, in plugin order.
    @Test(arguments: [
        (PluginCommandSlot.palette, ["io.a/new", "io.a/both"]),
        (.worktreeMenu, ["io.a/both"]),
        (.toolbar, []),
    ])
    func aSlotShowsTheCommandsOfActivePlugins(slot: PluginCommandSlot, expected: [String]) {
        let items = PluginCommandRouting.items(in: slot, projectID: "p", plugins: [
            (Self.plugin("io.a", [("new", [.palette]), ("both", [.palette, .worktreeMenu])]), true),
            (Self.plugin("io.b", [("off", [.palette, .worktreeMenu, .toolbar])]), false),
        ])
        #expect(items.map(\.id) == expected)
        #expect(items.allSatisfy { $0.projectID == "p" })
    }

    struct TargetCase: Sendable {
        let slot: PluginCommandSlot
        let worktreeID: String?
        var detail: String?
        var text: String?
        let expected: String?
    }

    @Test(arguments: [
        TargetCase(slot: .palette, worktreeID: "w1", expected: #"{"kind":"project"}"#),
        TargetCase(slot: .menubar, worktreeID: nil, expected: #"{"kind":"project"}"#),
        TargetCase(slot: .repoMenu, worktreeID: "w1", expected: #"{"kind":"project"}"#),
        TargetCase(slot: .toolbar, worktreeID: "w1", expected: #"{"kind":"worktree","worktree":"w1"}"#),
        TargetCase(slot: .worktreeMenu, worktreeID: "w1", expected: #"{"kind":"worktree","worktree":"w1"}"#),
        TargetCase(slot: .worktreeMenu, worktreeID: nil, expected: nil),
        TargetCase(slot: .changesToolbar, worktreeID: "w1", expected: #"{"kind":"worktree","worktree":"w1"}"#),
        TargetCase(slot: .changesFileMenu, worktreeID: "w1", detail: "a/b.swift", expected: #"{"kind":"file","path":"a\/b.swift","worktree":"w1"}"#),
        TargetCase(slot: .changesFileMenu, worktreeID: "w1", expected: nil),
        TargetCase(slot: .changesCommitMenu, worktreeID: "w1", detail: "abc", expected: #"{"kind":"commit","sha":"abc","worktree":"w1"}"#),
        TargetCase(slot: .runMenu, worktreeID: "w1", detail: "repo:dev.sh", expected: #"{"kind":"run","script":"repo:dev.sh","worktree":"w1"}"#),
        TargetCase(slot: .runReport, worktreeID: nil, detail: "r1", expected: nil),
        TargetCase(slot: .runReport, worktreeID: "w1", detail: "r1", expected: #"{"kind":"runReport","run":"r1","worktree":"w1"}"#),
        TargetCase(slot: .sessionMenu, worktreeID: "w1", detail: "s1", expected: #"{"kind":"session","session":"s1"}"#),
        TargetCase(slot: .messageMenu, worktreeID: "w1", detail: "s1", text: "**hi**", expected: #"{"kind":"message","session":"s1","text":"**hi**"}"#),
        TargetCase(slot: .messageMenu, worktreeID: "w1", detail: "s1", expected: nil),
    ])
    func theTargetFollowsTheSlot(_ c: TargetCase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let target = try PluginCommandRouting.target(for: c.slot, worktreeID: c.worktreeID, detail: c.detail, text: c.text).map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }
        #expect(target == c.expected)
    }

    /// A clicked badge sends its row's target, like that row's menu.
    @Test(arguments: [
        (PluginDecorationKey(slot: .repoRow, target: "p"), #"{"kind":"project"}"#),
        (PluginDecorationKey(slot: .worktreeRow, target: "w1"), #"{"kind":"worktree","worktree":"w1"}"#),
        (PluginDecorationKey(slot: .runRow, worktree: "w1", target: "repo:dev.sh"), #"{"kind":"run","script":"repo:dev.sh","worktree":"w1"}"#),
        (PluginDecorationKey(slot: .changesFile, worktree: "w1", target: "a.swift"), #"{"kind":"file","path":"a.swift","worktree":"w1"}"#),
    ])
    func aBadgeTargetsItsRow(key: PluginDecorationKey, expected: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let target = try #require(PluginCommandRouting.target(for: key))
        #expect(String(decoding: try encoder.encode(target), as: UTF8.self) == expected)
    }

    /// A command name reaches one plugin: Alas's own `/btw` and an earlier plugin's prompt win.
    @Test(arguments: [
        ("/linear  ENG-123 ", "io.a", "ENG-123"),
        ("/todo", "io.b", ""),
        ("/btw why", nil, nil),
        ("/linearx", nil, nil),
    ] as [(String, String?, String?)])
    func aPromptCommandMatchesTheFirstPluginThatOffersIt(text: String, pluginID: String?, args: String?) {
        func plugin(_ id: String, _ names: [String], active: Bool = true) -> (manifest: PluginManifest, isActive: Bool) {
            (PluginManifest(id: id, name: id, version: "1", api: 7, entry: "p.js", capabilities: [],
                            prompts: names.map { PluginPromptContribution(name: $0) }), active)
        }
        let items = PluginPromptItem.items([
            plugin("io.off", ["todo"], active: false), plugin("io.a", ["linear", "btw"]), plugin("io.b", ["linear", "todo"]),
        ])
        #expect(items.map(\.suggestion.command) == ["/linear", "/todo"])
        let match = PluginPromptItem.match(text, in: items)
        #expect(match?.item.pluginID == pluginID)
        #expect(match?.args == args)
    }
}
