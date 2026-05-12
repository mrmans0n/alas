import Foundation
import Testing
@testable import Alas

struct ProjectPickerTests {
    @Test func emptySearchReturnsAllProjectsInOrder() {
        let projects = [
            Self.project(name: "Alpha"),
            Self.project(name: "Beta"),
            Self.project(name: "Gamma")
        ]

        let result = ProjectPicker.filteredProjects(projects, search: "")

        #expect(result.map(\.name) == ["Alpha", "Beta", "Gamma"])
    }

    @Test func searchFiltersCaseInsensitively() {
        let projects = [
            Self.project(name: "Alpha"),
            Self.project(name: "beta"),
            Self.project(name: "GAMMA"),
            Self.project(name: "Delta")
        ]

        let result = ProjectPicker.filteredProjects(projects, search: "ALP")
        #expect(result.map(\.name) == ["Alpha"])
    }

    @Test func searchPreservesRelativeOrder() {
        let projects = [
            Self.project(name: "Alpha"),
            Self.project(name: "App"),
            Self.project(name: "Beta"),
            Self.project(name: "Another")
        ]

        let result = ProjectPicker.filteredProjects(projects, search: "a")
        #expect(result.map(\.name) == ["Alpha", "App", "Beta", "Another"])
    }

    @Test func searchWithNoMatchesReturnsEmpty() {
        let projects = [
            Self.project(name: "Alpha"),
            Self.project(name: "Beta")
        ]

        let result = ProjectPicker.filteredProjects(projects, search: "zzz")
        #expect(result.isEmpty)
    }

    private static func project(name: String) -> ProjectConfig {
        ProjectConfig(
            id: UUID().uuidString,
            name: name,
            path: "/tmp/\(name)",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
