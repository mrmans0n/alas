import AppKit
import Foundation
import Testing

@testable import Alas

@MainActor
@Suite struct ACPMessageActionsMenuTests {
    private func input(
        markdown: String = "Hello **there**",
        checkpoint: CheckpointID? = nil,
        forkTargets: [ACPSessionForkTarget] = [],
        quoted: @escaping (String) -> Void = { _ in }
    ) -> ACPMessageActionsMenu.Input {
        .init(
            markdown: { markdown }, createdAt: Date(timeIntervalSince1970: 0), checkpointID: checkpoint,
            forkBoundary: forkTargets.isEmpty ? nil : ACPForkMessageBoundary(stableID: "m1", kind: .agent),
            forkTargets: forkTargets, onQuote: quoted, onFork: { _, _ in }, onRestoreCheckpoint: { _ in },
            messageMenuItems: { [] }
        )
    }

    private func actionTitles(_ menu: NSMenu) -> [String] {
        menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    @Test func quoteUsesTheMessageMarkdown() throws {
        var quoted: String?
        let menu = ACPMessageActionsMenu.make(input(quoted: { quoted = $0 }))
        let quote = try #require(menu.items.first { $0.title == "Quote" })
        menu.performActionForItem(at: menu.index(of: quote))
        #expect(quoted == "Hello **there**")
    }

    @Test func restoreAndForkEntriesAppearWhenAvailable() throws {
        let targets = [ACPSessionForkTarget(id: "a", displayName: "Agent A", logoAssetName: nil, isSameAgent: true)]
        let menu = ACPMessageActionsMenu.make(input(checkpoint: UUID(), forkTargets: targets))
        let titles = actionTitles(menu)
        #expect(titles.contains("Restore files to before this request"))
        let fork = try #require(menu.items.first { $0.title == "Fork from here" })
        #expect(fork.submenu?.items.map(\.title) == ["Agent A"])
    }
}
