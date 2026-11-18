import AlasCore
import Foundation
import SwiftUI
import Testing
@testable import Alas

struct WorktreeRowPresentationTests {
    /// The prefix ends at the last slash; a name without one is all leaf.
    @Test(arguments: [
        ("nacho/refactor-transcript", "nacho/", "refactor-transcript"),
        ("team/nacho/fix", "team/nacho/", "fix"),
        ("main", "", "main"),
        ("odd/", "", "odd/"),
    ])
    func branchNameSplitsAtLastSlash(title: String, prefix: String, leaf: String) {
        let parts = WorktreeRowPresentation.nameParts(title)
        #expect(parts.prefix == prefix)
        #expect(parts.leaf == leaf)
    }

    /// A plain file count is the only state without a coloured dot.
    @Test(arguments: [
        (HarnessService.AggregatedState?.some(.running), WorktreeDirtyState.clean, true),
        (.some(.awaiting), .dirty(fileCount: 3, conflictCount: 0), true),
        (nil, .dirty(fileCount: 3, conflictCount: 1), true),
        (nil, .dirty(fileCount: 3, conflictCount: 0), false),
        (nil, .clean, false),
        (nil, .unknown, false),
    ])
    func loudStatus(harnessState: HarnessService.AggregatedState?, worktreeStatus: WorktreeDirtyState, loud: Bool) {
        #expect(WorktreeRowPresentation.isStatusLoud(harnessState: harnessState, worktreeStatus: worktreeStatus) == loud)
    }

    @Test(arguments: [
        (TimeInterval(30), "now"), (90, "1m"), (3_700, "1h"), (90_000, "1d"),
        (700_000, "1w"), (2_700_000, "1mo"), (32_000_000, "1y"),
    ])
    func compactAgeFitsBesideAName(elapsed: TimeInterval, expected: String) {
        let now = Date(timeIntervalSince1970: 100_000_000)
        #expect(WorktreeRowPresentation.compactAge(since: now.addingTimeInterval(-elapsed), now: now) == expected)
    }

    /// Rounds down, so a count never reads larger than it is.
    @Test(arguments: [
        (840, "840"), (999, "999"), (1_000, "1k"), (1_340, "1.3k"), (9_999, "9.9k"),
        (22_230, "22k"), (999_999, "999k"), (1_250_000, "1.2M"), (12_000_000, "12M"),
    ])
    func compactCountFitsARow(count: Int, expected: String) {
        #expect(WorktreeRowPresentation.compactCount(count) == expected)
    }

    @Test(arguments: ["cool-slate", "light"], ["add", "del", "mod", "warn", "caution", "accent", "fg-dim"])
    func statusTextReachesContrastOnTheSelectedFill(themeId: String, token: String) throws {
        let theme = try Theme.loadBundled(id: themeId)
        let fillToken = WorktreeRowView.sidebarFillToken
        let ratio = Color.contrastRatio(theme.legibleOnSelection(token, over: fillToken), theme.selectionFill(over: fillToken))
        #expect(ratio >= 4.5, "\(token) on \(themeId): \(ratio)")
    }

    @Test func beingBehindUpstreamIsVisibleAtRestAndBeingAheadIsNot() {
        let items = WorktreeUpstreamStatus(ahead: 2, behind: 3, upstreamRef: "origin/main").subtitleItems

        #expect(WorktreeRowPresentation.upstreamItemsAtRest(items).map(\.text) == ["↓3"])
    }

    /// Reads the fields by reflection, so a new one the label forgets fails here.
    @Test func accessibilityLabelSaysEveryFieldARowCanHave() {
        let content = WorktreeRowAccessibilityContent(
            name: "feat/invoice-export",
            statusNote: "1 file",
            added: 48,
            deleted: 6,
            workspaceCheckout: "Workspace Release",
            commits: "2 commits beyond main",
            upstream: ["1 commit behind origin/main"],
            stack: "gg stack · 1 of 3 commits merged",
            agents: ["Claude · running"],
            explanation: "Adds invoice export",
            lastActivity: "9 mo ago"
        )
        let label = WorktreeRowPresentation.accessibilityLabel(content)
        for field in Mirror(reflecting: content).children {
            let values: [String]
            switch field.value {
            case let list as [String]: values = list
            case let text as String: values = [text]
            case let number as Int: values = ["\(number) lines"]
            default:
                Issue.record("Unhandled field \(field.label ?? "?")")
                values = []
            }
            for value in values {
                #expect(label.contains(value), "\(field.label ?? "?") is missing from the label")
            }
        }
    }

    @Test func accessibilityLabelSkipsWhatARowDoesNotHave() {
        let label = WorktreeRowPresentation.accessibilityLabel(WorktreeRowAccessibilityContent(
            name: "main",
            statusNote: nil,
            added: 0,
            deleted: 0,
            workspaceCheckout: nil,
            commits: nil,
            upstream: [],
            stack: nil,
            agents: [],
            explanation: nil,
            lastActivity: "9 mo ago"
        ))
        #expect(label == "main, 9 mo ago")
    }

    /// Only rows a linked record contributes to its primary's group get a badge.
    @Test(arguments: [
        ("L", "devbox", RemoteHostReachability.online, WorktreeRowPresentation.MachineBadge?.none),
        ("R", "devbox", .online, .some(.init(label: "Dev Box", state: .online))),
        ("R", "mini", .unknown, .some(.init(label: "mini", state: .unknown))),
        ("R", "devbox", .offline, .some(.init(label: "Dev Box", state: .offline))),
    ])
    func machineBadgeShowsOnlyOnLinkedRows(
        rowProjectId: String, host: String, reachability: RemoteHostReachability,
        expected: WorktreeRowPresentation.MachineBadge?
    ) {
        let badge = WorktreeRowPresentation.machineBadge(
            rowProjectId: rowProjectId,
            groupProjectId: "L",
            host: host,
            machines: [Machine(destination: "devbox", label: "Dev Box", projectsFolder: "~/code")],
            reachability: reachability
        )
        #expect(badge == expected)
    }

    // MARK: - Live activity

    typealias Glyph = WorktreeRowPresentation.ResourceGlyph

    private static let savedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static func vmGlyph(_ guest: VMGuestOS, _ state: WorktreeRowPresentation.ResourceState, count: Int, _ tooltip: String) -> Glyph {
        Glyph(kind: .vm(guest), state: state, count: count, tooltip: tooltip, deviceID: nil)
    }

    @Test(arguments: [
        ([.macOS: .running], [vmGlyph(.macOS, .on, count: 1, "macOS VM running")]),
        ([.macOS: .running, .linux: .starting],
         [vmGlyph(.linux, .starting, count: 2, "macOS VM running, Linux VM starting")]),
        ([.macOS: .pausing], [vmGlyph(.macOS, .starting, count: 1, "macOS VM pausing")]),
        ([.linux: .paused(savedAt: savedAt)], [vmGlyph(.linux, .paused, count: 1, "Linux VM paused")]),
        ([.macOS: .stopped, .linux: .notCreated], []),
        ([.macOS: .runningElsewhere(label: "other")], []),
    ] as [([VMGuestOS: VMDeviceStatus], [Glyph])])
    func vmsCollapseToOneGlyphInTheStrongestState(vms: [VMGuestOS: VMDeviceStatus], expected: [Glyph]) {
        #expect(WorktreeRowPresentation.resourceGlyphs(vms: vms, devices: []) == expected)
    }

    @Test func devicesShowOneGlyphPerPlatformAndSkipShutDownOnes() {
        typealias Device = WorktreeRowPresentation.OwnedDevice
        let glyphs = WorktreeRowPresentation.resourceGlyphs(vms: [:], devices: [
            Device(id: "A", name: "iPhone 17 Pro", isAndroid: false, state: .on),
            Device(id: "B", name: "iPad", isAndroid: false, state: nil),
            Device(id: "C", name: "Pixel 9", isAndroid: true, state: .starting),
        ])
        #expect(glyphs == [
            Glyph(kind: .iosSimulator, state: .on, count: 1, tooltip: "iPhone 17 Pro booted", deviceID: "A"),
            Glyph(kind: .androidEmulator, state: .starting, count: 1, tooltip: "Pixel 9 (emulator) booting", deviceID: "C"),
        ])
        let shutDown = [Device(id: "B", name: "iPad", isAndroid: false, state: nil)]
        #expect(WorktreeRowPresentation.resourceGlyphs(vms: [:], devices: shutDown).isEmpty)
    }

    @Test(arguments: [
        (StackShipActivity.running(sessionID: "s", progress: StackShipProgress(phase: .linting, position: 2, totalEntries: 4)),
         "Shipping stack · linting", 2 as Int?, 4 as Int?),
        (.running(sessionID: "s", progress: StackShipProgress(phase: .checking, position: 1, totalEntries: 4)),
         "Shipping stack · checking", nil, nil),
    ])
    func runningShipShowsPhaseAndBarOnlyWhileLintingOrPushing(
        activity: StackShipActivity, title: String, position: Int?, total: Int?
    ) {
        let line = WorktreeRowPresentation.shipLine(activity)
        #expect(line?.title == title)
        #expect(line?.position == position)
        #expect(line?.total == total)
        #expect(line?.isFailure == false)
        #expect(line?.sessionID == "s")
    }

    @Test func failedShipTitlesTheFirstLineAndKeepsTheWholeMessageInTheTooltip() {
        let line = WorktreeRowPresentation.shipLine(.failed(sessionID: "s", message: "gg sync failed\nmore"))
        #expect(line?.title == "Ship failed: gg sync failed")
        #expect(line?.isFailure == true)
        #expect(line?.tooltip == "gg sync failed\nmore")
        let long = WorktreeRowPresentation.shipLine(.failed(sessionID: "s", message: String(repeating: "x", count: 80)))
        #expect(long?.title == "Ship failed: " + String(repeating: "x", count: 60) + "…")
        #expect(WorktreeRowPresentation.shipLine(nil) == nil)
    }

    private static let remote = CodeHostRemote(
        kind: .github, host: "github.com", owner: "acme", repository: "app",
        remoteName: "origin", webURL: URL(string: "https://github.com/acme/app")!
    )

    private static func prRecord(_ phase: ShepherdPhase, number: Int = 7) -> ShepherdRecord {
        var record = ShepherdRecord(
            id: ShepherdRecordID(worktreeID: "wt", providerKind: .github, host: remote.host,
                                 repositorySlug: remote.repositorySlug, requestNumber: number),
            sessionID: "pr-session", remote: remote, branch: "b", baseBranch: "main",
            autoFix: true, autoMerge: false, now: savedAt
        )
        record.phase = phase
        return record
    }

    private static func stackRecord(_ phases: [ShepherdPhase]) -> StackShepherdRecord {
        let entries = phases.enumerated().map { index, phase in
            StackShepherdEntry(entryID: "e\(index)", position: index + 1, title: "t",
                               shepherd: prRecord(phase, number: 10 + index))
        }
        return StackShepherdRecord(
            id: StackShepherdRecordID(worktreeID: "wt", stackName: "s"), sessionID: "stack-session",
            remote: remote, base: "main", autoFix: true, entries: entries, now: savedAt
        )
    }

    @Test(arguments: [
        (ShepherdPhase.watching, "#7", nil as String?),
        (.fixing(dispatchedAt: savedAt), "#7", "agent fixing"),
        (.merging, "#7", "merging"),
        (.queued, "#7", "in merge queue"),
        (.escalated(.attemptsExhausted), "#7", "needs you"),
        (.paused, "#7", "needs you"),
    ])
    func prShepherdMapsItsBadgeToANote(phase: ShepherdPhase, number: String, note: String?) {
        let result = WorktreeRowPresentation.shepherdNote(pr: Self.prRecord(phase), stack: nil)
        #expect(result?.number == number)
        #expect(result?.note == note)
        #expect(result?.sessionID == "pr-session")
        #expect(result?.replacesStackChip == false)
    }

    @Test func mergedAndClosedPRShepherdsSayNothing() {
        #expect(WorktreeRowPresentation.shepherdNote(pr: Self.prRecord(.merged), stack: nil) == nil)
        #expect(WorktreeRowPresentation.shepherdNote(pr: Self.prRecord(.closed), stack: nil) == nil)
        #expect(WorktreeRowPresentation.shepherdNote(pr: nil, stack: nil) == nil)
    }

    @Test func stackShepherdCountsPRsReplacesTheStackChipAndBeatsAPRShepherd() {
        let stack = Self.stackRecord([.merged, .watching, .watching, .watching])
        let result = WorktreeRowPresentation.shepherdNote(pr: Self.prRecord(.watching), stack: stack)
        #expect(result?.number == "4 PRs")
        #expect(result?.note == "1 merged")
        #expect(result?.replacesStackChip == true)
        #expect(result?.sessionID == "stack-session")

        let fixing = Self.stackRecord([.watching, .fixing(dispatchedAt: Self.savedAt)])
        #expect(WorktreeRowPresentation.shepherdNote(pr: nil, stack: fixing)?.note == "agent fixing")
        let stuck = Self.stackRecord([.watching, .escalated(.noProgress)])
        #expect(WorktreeRowPresentation.shepherdNote(pr: nil, stack: stuck)?.note == "need you")
        #expect(WorktreeRowPresentation.shepherdNote(pr: nil, stack: Self.stackRecord([.merged, .merged])) == nil)
    }

    @Test(arguments: [
        (ShepherdPhase.escalated(.deliveryFailed), true),
        (.paused, true),
        (.watching, false),
        (.fixing(dispatchedAt: savedAt), false),
        (.merging, false),
        (.queued, false),
    ])
    func shepherdNoteLoudness(phase: ShepherdPhase, isLoud: Bool) {
        #expect(WorktreeRowPresentation.shepherdNote(pr: Self.prRecord(phase), stack: nil)?.isLoud == isLoud)
    }
}
