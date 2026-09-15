import Foundation
import Testing
@testable import Alas

@MainActor
struct CenterPaneRightRailRevealTests {
    @Test func selectedRailSuppressesTheLegacyCenterPaneRevealWhileNoRailKeepsIt() throws {
        let source = try centerPaneSource()

        #expect(source.contains("rightSidebarHidden: Self.showsLegacyRightSidebarReveal("))
        #expect(!CenterPaneView.showsLegacyRightSidebarReveal(
            rightPaneRailExists: true,
            rightPaneVisible: false
        ))
        #expect(CenterPaneView.showsLegacyRightSidebarReveal(
            rightPaneRailExists: false,
            rightPaneVisible: false
        ))
    }
}

private func centerPaneSource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: root.appendingPathComponent("Alas/Sources/Center/CenterPaneView.swift"),
        encoding: .utf8
    )
}
