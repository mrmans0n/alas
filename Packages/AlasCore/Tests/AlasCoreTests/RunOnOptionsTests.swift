import Foundation
import Testing
@testable import AlasCore

struct RunOnOptionsTests {
    private static let primary = ProjectConfig(
        id: "p", name: "alas", path: "/Users/n/code/alas", color: "blue", addedAt: Date(timeIntervalSince1970: 0)
    )

    private static func record(_ host: String) -> ProjectConfig {
        var project = ProjectConfig(
            id: "r-\(host)", name: "alas", path: RemotePath.virtual(host: host, realPath: "/srv/alas"),
            color: "blue", addedAt: Date(timeIntervalSince1970: 0), host: host
        )
        project.linkedProjectId = "p"
        return project
    }

    private static let machines = [
        Machine(destination: "devbox", label: "Devbox", projectsFolder: "~/code"),
        Machine(destination: "mini", label: "Mac mini", projectsFolder: "~/src"),
        Machine(destination: "fresh", projectsFolder: "~/code"),
    ]

    private static func options(hasOrigin: Bool = true) -> [RunOnOption] {
        RunOnOptions.make(
            primary: primary,
            hasOrigin: hasOrigin,
            linked: [record("mini"), record("old"), record("devbox")],
            machines: machines,
            reachability: { $0 == "mini" ? .offline : .online }
        )
    }

    @Test func listsThisMacThenReadyMachinesThenMachinesNeedingSetup() {
        #expect(Self.options() == [
            RunOnOption(host: nil, label: "This Mac", detail: "/Users/n/code/alas", kind: .thisMac, disabledReason: nil),
            RunOnOption(
                host: "devbox", label: "Devbox", detail: "devbox:/srv/alas",
                kind: .ready(projectId: "r-devbox", reachability: .online), disabledReason: nil
            ),
            RunOnOption(
                host: "mini", label: "Mac mini", detail: "mini:/srv/alas",
                kind: .ready(projectId: "r-mini", reachability: .offline), disabledReason: nil
            ),
            RunOnOption(
                host: "old", label: "old", detail: "old:/srv/alas",
                kind: .ready(projectId: "r-old", reachability: .online), disabledReason: nil
            ),
            RunOnOption(
                host: "fresh", label: "fresh", detail: "Will set up in ~/code",
                kind: .needsSetup, disabledReason: RunOnOptions.needsSetupReason
            ),
        ])
    }

    @Test func withoutAnOriginOnlyThisMacCanRunIt() {
        let enabled = Self.options(hasOrigin: false).filter { $0.disabledReason == nil }.map(\.host)
        #expect(enabled == [nil])
        #expect(Self.options(hasOrigin: false).dropFirst().allSatisfy { $0.disabledReason == RunOnOptions.noOriginReason })
    }

    @Test(arguments: [
        (last: nil, hasOrigin: true, expected: nil),
        (last: "mini", hasOrigin: true, expected: "mini"),
        (last: "removed", hasOrigin: true, expected: nil),
        (last: "fresh", hasOrigin: true, expected: nil),
        (last: "mini", hasOrigin: false, expected: nil),
    ] as [(last: String?, hasOrigin: Bool, expected: String?)])
    func preselectsTheLastMachineOnlyWhileItCanRunIt(last: String?, hasOrigin: Bool, expected: String?) {
        #expect(RunOnOptions.preselectedHost(in: Self.options(hasOrigin: hasOrigin), lastRunOnHost: last) == expected)
    }
}
