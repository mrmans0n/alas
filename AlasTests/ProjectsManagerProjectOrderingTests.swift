import Testing
import Foundation
@testable import Alas

@MainActor
@Suite(.serialized)
struct ProjectsManagerProjectOrderingTests {
    private func makeProjects(_ names: [String]) -> [ProjectConfig] {
        names.enumerated().map { index, name in
            ProjectConfig(
                id: name,
                name: name,
                path: "/repos/\(name)",
                color: "blue",
                addedAt: Date(timeIntervalSince1970: Double(index))
            )
        }
    }

    // MARK: - reorderProject(fromIndex:toIndex:)

    @Test func reorderMovesProjectToNewPosition() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C"]))

        mgr.reorderProject(fromIndex: 0, toIndex: 2)

        #expect(mgr.projects.map(\.id) == ["B", "C", "A"])
    }

    @Test func reorderMovesProjectForward() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C", "D"]))

        mgr.reorderProject(fromIndex: 3, toIndex: 1)

        #expect(mgr.projects.map(\.id) == ["A", "D", "B", "C"])
    }

    @Test func reorderSameIndexIsNoOp() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C"]))

        mgr.reorderProject(fromIndex: 1, toIndex: 1)

        #expect(mgr.projects.map(\.id) == ["A", "B", "C"])
    }

    @Test func reorderOutOfBoundsFromIndexIsNoOp() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B"]))

        mgr.reorderProject(fromIndex: 5, toIndex: 0)

        #expect(mgr.projects.map(\.id) == ["A", "B"])
    }

    @Test func reorderOutOfBoundsToIndexIsNoOp() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B"]))

        mgr.reorderProject(fromIndex: 0, toIndex: 5)

        #expect(mgr.projects.map(\.id) == ["A", "B"])
    }

    @Test func reorderSwapsAdjacentProjects() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C"]))

        mgr.reorderProject(fromIndex: 0, toIndex: 1)

        #expect(mgr.projects.map(\.id) == ["B", "A", "C"])
    }

    // MARK: - reorderProject(movingId:destinationId:)

    @Test func reorderByIdMovesToDestination() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C"]))

        mgr.reorderProject(movingId: "C", destinationId: "A")

        #expect(mgr.projects.map(\.id) == ["C", "A", "B"])
    }

    @Test func reorderByIdSameIdIsNoOp() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C"]))

        mgr.reorderProject(movingId: "B", destinationId: "B")

        #expect(mgr.projects.map(\.id) == ["A", "B", "C"])
    }

    @Test func reorderByIdUnknownIdIsNoOp() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B"]))

        mgr.reorderProject(movingId: "Z", destinationId: "A")

        #expect(mgr.projects.map(\.id) == ["A", "B"])
    }

    @Test func reorderByIdMovesLastToFirst() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C", "D"]))

        mgr.reorderProject(movingId: "D", destinationId: "A")

        #expect(mgr.projects.map(\.id) == ["D", "A", "B", "C"])
    }

    @Test func reorderByIdMovesFirstToLast() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C", "D"]))

        mgr.reorderProject(movingId: "A", destinationId: "D")

        #expect(mgr.projects.map(\.id) == ["B", "C", "D", "A"])
    }

    // MARK: - moveProjectToEnd(id:)

    @Test func moveToEndMovesFirstProjectToEnd() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C"]))

        mgr.moveProjectToEnd(id: "A")

        #expect(mgr.projects.map(\.id) == ["B", "C", "A"])
    }

    @Test func moveToEndMovesMiddleProjectToEnd() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C", "D"]))

        mgr.moveProjectToEnd(id: "B")

        #expect(mgr.projects.map(\.id) == ["A", "C", "D", "B"])
    }

    @Test func moveToEndAlreadyLastIsNoOp() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B", "C"]))

        mgr.moveProjectToEnd(id: "C")

        #expect(mgr.projects.map(\.id) == ["A", "B", "C"])
    }

    @Test func moveToEndUnknownIdIsNoOp() {
        let mgr = ProjectsManager(persistedProjects: makeProjects(["A", "B"]))

        mgr.moveProjectToEnd(id: "Z")

        #expect(mgr.projects.map(\.id) == ["A", "B"])
    }

    // MARK: - persistence roundtrip

    @Test func projectOrderIsDeterminedByArrayPosition() {
        let projects = makeProjects(["X", "Y", "Z"])
        let file = ProjectsFile(projects: projects)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try! encoder.encode(file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try! decoder.decode(ProjectsFile.self, from: data)
        #expect(decoded.projects.map(\.id) == ["X", "Y", "Z"])
    }
}
