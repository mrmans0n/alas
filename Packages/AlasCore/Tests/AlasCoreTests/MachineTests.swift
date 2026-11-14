import Foundation
import Testing
@testable import AlasCore

struct MachineTests {
    @Test(arguments: [
        ("/Users/n/code", "/Users/n", "~/code"),
        ("/Users/n/src/repos", "/Users/n", "~/src/repos"),
        ("", "/Users/n", "~/code"),
        ("/Volumes/W/alas", "/Users/n", "~/code"),
        ("/Users/n", "/Users/n", "~/code"),
        ("/Users/nn/code", "/Users/n", "~/code"),
    ])
    func defaultProjectsFolderMirrorsTheLocalCloneRoot(cloneRoot: String, home: String, expected: String) {
        #expect(Machine.defaultProjectsFolder(cloneRoot: cloneRoot, localHome: home) == expected)
    }

    @Test func seedingAddsProjectHostsInOrder() {
        let seeded = Machine.seeded([], projectHosts: ["mini", "devbox", "mini"], defaultProjectsFolder: "~/code")
        #expect(seeded == [
            Machine(destination: "mini", projectsFolder: "~/code"),
            Machine(destination: "devbox", projectsFolder: "~/code"),
        ])
        #expect(seeded.map(\.label) == ["mini", "devbox"])
    }

    @Test func seedingKeepsExistingMachines() {
        let mini = Machine(destination: "mini", label: "Mac mini", projectsFolder: "~/src")
        let seeded = Machine.seeded([mini], projectHosts: ["mini", "devbox"], defaultProjectsFolder: "~/code")
        #expect(seeded == [mini, Machine(destination: "devbox", projectsFolder: "~/code")])
    }

    @Test func seedingSkipsUnroutableHosts() {
        let seeded = Machine.seeded(
            [],
            projectHosts: [RemotePath.unavailableHost, "-oProxy", ""],
            defaultProjectsFolder: "~/code"
        )
        #expect(seeded.isEmpty)
    }
}
