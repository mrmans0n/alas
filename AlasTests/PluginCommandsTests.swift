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
        let expected: String?
    }

    @Test(arguments: [
        TargetCase(slot: .palette, worktreeID: "w1", expected: #"{"kind":"project"}"#),
        TargetCase(slot: .menubar, worktreeID: nil, expected: #"{"kind":"project"}"#),
        TargetCase(slot: .repoMenu, worktreeID: "w1", expected: #"{"kind":"project"}"#),
        TargetCase(slot: .toolbar, worktreeID: "w1", expected: #"{"kind":"worktree","worktree":"w1"}"#),
        TargetCase(slot: .worktreeMenu, worktreeID: "w1", expected: #"{"kind":"worktree","worktree":"w1"}"#),
        TargetCase(slot: .worktreeMenu, worktreeID: nil, expected: nil),
    ])
    func theTargetFollowsTheSlot(_ c: TargetCase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let target = try PluginCommandRouting.target(for: c.slot, worktreeID: c.worktreeID).map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }
        #expect(target == c.expected)
    }
}
