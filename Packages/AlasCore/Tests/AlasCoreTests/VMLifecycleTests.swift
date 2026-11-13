import AlasModel
import Foundation
import Testing
@testable import AlasPlatform

@Suite struct VMLifecycleTests {
    private static let now = Date(timeIntervalSince1970: 100_000)

    private static func minutesAgo(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private struct IdleCase: CustomTestStringConvertible {
        var name: String
        var guest: VMGuestOS = .macOS
        var lastAgentCall: Date?
        var inFlight = false
        var lastUserInput: Date?
        var takenOver = false
        var starting = false
        var inSetupFlow = false
        var runningSince = VMLifecycleTests.minutesAgo(60)
        var expected: Bool
        var testDescription: String { name }
    }

    @Test(arguments: [
        IdleCase(name: "linux never pauses", guest: .linux, lastAgentCall: minutesAgo(60), expected: false),
        IdleCase(name: "in flight", lastAgentCall: minutesAgo(60), inFlight: true, expected: false),
        IdleCase(name: "call 14 min ago", lastAgentCall: minutesAgo(14), expected: false),
        IdleCase(name: "call 16 min ago", lastAgentCall: minutesAgo(16), expected: true),
        IdleCase(name: "input 5 min ago", lastAgentCall: minutesAgo(60), lastUserInput: minutesAgo(5), expected: false),
        IdleCase(name: "old input and call", lastAgentCall: minutesAgo(60), lastUserInput: minutesAgo(30), expected: true),
        IdleCase(name: "taken over", lastAgentCall: minutesAgo(60), takenOver: true, expected: false),
        IdleCase(name: "starting", lastAgentCall: minutesAgo(60), starting: true, expected: false),
        IdleCase(name: "setup flow", lastAgentCall: minutesAgo(60), inSetupFlow: true, expected: false),
        IdleCase(name: "booted 16 min ago, never used", runningSince: minutesAgo(16), expected: true),
        IdleCase(name: "booted 5 min ago, never used", runningSince: minutesAgo(5), expected: false),
    ])
    private func idlePolicy(_ c: IdleCase) {
        #expect(
            VMIdlePolicy.shouldPause(
                guest: c.guest, lastAgentCall: c.lastAgentCall, agentCallInFlight: c.inFlight,
                lastUserInput: c.lastUserInput, takenOver: c.takenOver, starting: c.starting,
                inSetupFlow: c.inSetupFlow, runningSince: c.runningSince, now: Self.now) == c.expected)
    }

    @Test func stateIsValidOnlyForTheDiskItWasSavedWith() {
        let disk = Date(timeIntervalSince1970: 5_000)
        #expect(VMSavedState.isValid(pausedDiskStamp: disk, currentDiskModified: disk))
        #expect(!VMSavedState.isValid(pausedDiskStamp: disk, currentDiskModified: disk.addingTimeInterval(1)))
        #expect(!VMSavedState.isValid(pausedDiskStamp: nil, currentDiskModified: disk))
    }

    private static func name(_ worktree: String, _ guest: VMGuestOS) -> String {
        "\(worktree.split(separator: "/").last!)\(guest == .linux ? "-linux" : "")"
    }

    private static func rec(_ worktree: String, _ guest: VMGuestOS = .macOS) -> WorktreeVMRecord {
        WorktreeVMRecord(
            id: VMIdentity.recordID(worktree: worktree, guest: guest), guestOS: guest, goldenBuild: "b",
            bundlePath: "", createdAt: .distantPast, lastUsedAt: .distantPast)
    }

    @Test(arguments: [
        (["ghost"], [WorktreeVMRecord](), ["ghost"]),
        (["gone"], [rec("/w/gone")], ["gone"]),
        (["live"], [rec("/w/live")], []),
        (["live-linux"], [rec("/w/live", .linux)], []),
        (["gone-linux"], [rec("/w/gone", .linux)], ["gone-linux"]),
        (["live", "live-linux"], [rec("/w/live")], ["live-linux"]),
    ] as [([String], [WorktreeVMRecord], [String])])
    private func orphans(bundles: [String], records: [WorktreeVMRecord], expected: [String]) {
        let found = VMOrphans.find(
            bundleNames: bundles, records: records,
            worktreeExists: { $0.hasSuffix("/live") }, bundleName: Self.name)
        #expect(found == expected)
    }

    @Test func scriptHashIgnoresBlankScripts() {
        #expect(VMCleanPoint.scriptHash(nil) == nil)
        #expect(VMCleanPoint.scriptHash(" \n\t") == nil)
        #expect(
            VMCleanPoint.scriptHash("abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func projectVMSettingsDefaultOffAndRoundTrip() throws {
        let base = ProjectConfig(id: "p", name: "R", path: "/tmp/r", color: "#fff", addedAt: .distantPast)
        let encoded = try JSONEncoder().encode(base)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["vmForNewWorktrees"] == nil && object["vmGuestSetupScript"] == nil)
        var project = try JSONDecoder().decode(ProjectConfig.self, from: encoded)
        #expect(project.vmForNewWorktrees == nil && project.vmGuestSetupScript == nil)

        project.vmForNewWorktrees = true
        project.vmGuestSetupScript = "brew install jq"
        let back = try JSONDecoder().decode(ProjectConfig.self, from: JSONEncoder().encode(project))
        #expect(back.vmForNewWorktrees == true)
        #expect(back.vmGuestSetupScript == "brew install jq")
    }

    // MARK: - Templates

    private static let sealedAt = Date(timeIntervalSince1970: 50_000)
    private static let template = VMTemplate(
        projectID: "p1", guest: .macOS, goldenBuild: "25A1", goldenSealedAt: sealedAt,
        setupScriptHash: "h", createdAt: now)

    @Test(arguments: [
        ("25A1", sealedAt, "h" as String?, true),
        ("25A1", sealedAt.addingTimeInterval(0.4), "h", true),
        ("25B1", sealedAt, "h", false),
        ("25A1", sealedAt.addingTimeInterval(60), "h", false),
        ("25A1", sealedAt, "other", false),
        ("25A1", sealedAt, nil, false),
    ])
    func templateMatching(build: String, sealedAt: Date, hash: String?, expected: Bool) {
        #expect(Self.template.matches(goldenBuild: build, goldenSealedAt: sealedAt, setupScriptHash: hash) == expected)
    }

    @Test(arguments: [
        (Set(["p2"]), ("25A1", sealedAt) as (String, Date)?, true),
        (Set(["p1"]), nil, true),
        (Set(["p1"]), ("25B1", sealedAt), true),
        (Set(["p1"]), ("25A1", sealedAt.addingTimeInterval(60)), true),
        (Set(["p1"]), ("25A1", sealedAt), false),
    ])
    func templateStaleness(live: Set<String>, golden: (String, Date)?, expected: Bool) {
        let current = golden.map { (build: $0.0, sealedAt: $0.1) }
        #expect(Self.template.isStale(liveProjectIDs: live, currentGolden: current) == expected)
    }

    @Test func templateSlotsDifferPerGuestAndAreSingleComponents() {
        let macOS = VMTemplate.slotName(projectID: "/a/b", guest: .macOS)
        #expect(macOS != VMTemplate.slotName(projectID: "/a/b", guest: .linux))
        #expect(!macOS.contains("/"))
    }
}
