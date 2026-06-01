import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct SpacesManagerTests {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func project(_ id: String) -> ProjectConfig {
        ProjectConfig(
            id: id,
            name: id.uppercased(),
            path: "/tmp/\(id)",
            color: "#5fb7c4",
            addedAt: date
        )
    }

    @Test func migratedDefaultContainsAllProjectsAndHidesAffordance() {
        let projects = [project("p1"), project("p2")]
        let manager = SpacesManager.migrating(projects: projects, now: date)

        #expect(manager.spaces.count == 1)
        #expect(manager.activeSpace?.name == SpaceConfig.defaultName)
        #expect(manager.activeSpace?.emoji == SpaceConfig.defaultEmoji)
        #expect(manager.activeSpace?.projectIds == ["p1", "p2"])
        #expect(!manager.shouldShowSpaceAffordance)
    }

    @Test func customizingDefaultShowsAffordance() {
        var manager = SpacesManager.migrating(projects: [project("p1")], now: date)

        manager.renameSpace(id: manager.activeSpaceId, name: "Work")
        #expect(manager.shouldShowSpaceAffordance)

        manager.renameSpace(id: manager.activeSpaceId, name: SpaceConfig.defaultName)
        manager.setEmoji(spaceId: manager.activeSpaceId, emoji: "💼")
        #expect(manager.shouldShowSpaceAffordance)
    }

    @Test func addingSecondSpaceShowsAffordance() {
        var manager = SpacesManager.migrating(projects: [project("p1")], now: date)

        let newId = manager.addSpace(name: "Personal", emoji: "🏠", now: date.addingTimeInterval(1))

        #expect(manager.spaces.map(\.id).contains(newId))
        #expect(manager.shouldShowSpaceAffordance)
    }

    @Test func projectCanBelongToMultipleSpaces() {
        var manager = SpacesManager.migrating(projects: [project("p1"), project("p2")], now: date)
        let workId = manager.activeSpaceId
        let personalId = manager.addSpace(name: "Personal", emoji: "🏠", now: date)

        manager.addProject("p1", toSpace: personalId)

        #expect(manager.space(id: workId)?.projectIds == ["p1", "p2"])
        #expect(manager.space(id: personalId)?.projectIds == ["p1"])
    }

    @Test func finalProjectMembershipCannotBeRemoved() {
        var manager = SpacesManager.migrating(projects: [project("p1")], now: date)

        let removed = manager.removeProject("p1", fromSpace: manager.activeSpaceId)

        #expect(!removed)
        #expect(manager.activeSpace?.projectIds == ["p1"])
    }

    @Test func globalProjectRemovalPrunesAllSpaces() {
        var manager = SpacesManager.migrating(projects: [project("p1"), project("p2")], now: date)
        let second = manager.addSpace(name: "Side", emoji: "🧪", now: date)
        manager.addProject("p1", toSpace: second)

        manager.removeProjectEverywhere("p1")

        #expect(manager.spaces.allSatisfy { !$0.projectIds.contains("p1") })
        #expect(manager.space(id: manager.activeSpaceId)?.projectIds == ["p2"])
    }

    @Test func deletingActiveSpaceSwitchesToNeighborAndKeepsProjects() {
        var manager = SpacesManager.migrating(projects: [project("p1")], now: date)
        let second = manager.addSpace(name: "Side", emoji: "🧪", now: date)
        manager.switchToSpace(id: second)

        let deleted = manager.deleteSpace(id: second)

        #expect(deleted)
        #expect(manager.activeSpaceId == manager.spaces[0].id)
        #expect(manager.spaces.count == 1)
        #expect(manager.spaces[0].projectIds == ["p1"])
    }

    @Test func cannotDeleteFinalSpace() {
        var manager = SpacesManager.migrating(projects: [project("p1")], now: date)

        let deleted = manager.deleteSpace(id: manager.activeSpaceId)

        #expect(!deleted)
        #expect(manager.spaces.count == 1)
    }

    @Test func activeProjectsFollowSpaceOrderAndPruneMissingIds() {
        var manager = SpacesManager(
            file: SpacesFile(
                version: 1,
                activeSpaceId: "s1",
                spaces: [
                    SpaceConfig(
                        id: "s1",
                        name: "Work",
                        emoji: "💼",
                        projectIds: ["p2", "missing", "p1"],
                        lastSelectedWorktreeId: nil,
                        createdAt: date
                    )
                ]
            )
        )
        let projects = [project("p1"), project("p2")]

        let active = manager.activeProjects(from: projects)
        let pruned = manager.pruneMissingProjects(validProjectIds: Set(projects.map(\.id)))

        #expect(active.map(\.id) == ["p2", "p1"])
        #expect(pruned)
        #expect(manager.activeSpace?.projectIds == ["p2", "p1"])
    }

    @Test func reordersProjectsWithinActiveSpaceOnly() {
        var manager = SpacesManager.migrating(projects: [project("p1"), project("p2"), project("p3")], now: date)
        let second = manager.addSpace(name: "Other", emoji: "🧪", now: date)
        manager.addProject("p1", toSpace: second)
        manager.addProject("p2", toSpace: second)

        manager.reorderProjectInActiveSpace(movingId: "p3", destinationId: "p1")

        #expect(manager.activeSpace?.projectIds == ["p3", "p1", "p2"])
        #expect(manager.space(id: second)?.projectIds == ["p1", "p2"])
    }

    @Test func moveProjectToEndAffectsOnlyActiveSpace() {
        var manager = SpacesManager.migrating(projects: [project("p1"), project("p2")], now: date)

        manager.moveProjectToEndInActiveSpace(id: "p1")

        #expect(manager.activeSpace?.projectIds == ["p2", "p1"])
    }
}
