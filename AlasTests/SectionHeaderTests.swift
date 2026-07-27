import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct SectionHeaderTests {
    @Test func semanticRolesUseTheExpectedIconKinds() {
        #expect(SectionHeaderRole.workingTree.iconKind == .standard("diff"))
        #expect(SectionHeaderRole.commits.iconKind == .standard("commit"))
        #expect(SectionHeaderRole.stack.iconKind == .stack)
        #expect(SectionHeaderRole.stashes.iconKind == .standard("archivebox"))
    }

    @Test func collapsedHeaderUsesCollapsedAccessibilityValue() {
        #expect(SectionHeaderRole.accessibilityValue(expanded: false) == "Collapsed")
    }

    @Test func expandedHeaderUsesExpandedAccessibilityValue() {
        #expect(SectionHeaderRole.accessibilityValue(expanded: true) == "Expanded")
    }
}
