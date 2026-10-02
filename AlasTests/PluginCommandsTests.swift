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
    ])
    func theTargetFollowsTheSlot(_ c: TargetCase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let target = try PluginCommandRouting.target(for: c.slot, worktreeID: c.worktreeID, detail: c.detail).map {
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
}
