import Foundation
import Testing
@testable import Alas

/// What a composed schedule may claim. Occupancy is two questions — is the
/// path taken, is the branch taken — and both have to be answered against the
/// host that will run `git worktree add`, not against this Mac.
@Suite
struct ScheduledWorktreeDestinationTests {
    private func firstFree(
        _ rendered: String,
        existingBranches: Set<String> = [],
        occupiedPaths: Set<String> = [],
        unknownPaths: Set<String> = [],
        limit: Int = 50
    ) async -> ScheduledWorktreeDestination.Outcome {
        await ScheduledWorktreeDestination.firstFree(
            rendered: rendered,
            pathTemplate: "{worktreeRoot}/{repo}/{branch}",
            worktreeRoot: "/wts",
            repoName: "alas",
            existingBranches: existingBranches,
            limit: limit,
            pathState: { destination in
                let name = destination.lastPathComponent
                if unknownPaths.contains(name) { return .unknown }
                return occupiedPaths.contains(name) ? .occupied : .free
            }
        )
    }

    @Test func takesTheRenderedNameWhenNothingHoldsIt() async {
        let outcome = await firstFree("nightly")
        #expect(outcome == .free(branch: "nightly", destination: URL(fileURLWithPath: "/wts/alas/nightly")))
    }

    @Test func suffixesPastAnOccupiedDestination() async {
        let outcome = await firstFree("nightly", occupiedPaths: ["nightly"])
        #expect(outcome == .free(branch: "nightly-2", destination: URL(fileURLWithPath: "/wts/alas/nightly-2")))
    }

    /// The path being free is not enough. `WorktreeService.add` checks an
    /// existing branch out at its own tip instead of branching from the base,
    /// so reusing a retained branch would run the schedule against stale code.
    @Test func skipsARetainedBranchEvenWhenItsPathIsFree() async {
        let outcome = await firstFree("nightly", existingBranches: ["nightly"])
        #expect(outcome == .free(branch: "nightly-2", destination: URL(fileURLWithPath: "/wts/alas/nightly-2")))
    }

    @Test func skipsPastEveryFlavourOfTakenUntilOneIsFree() async {
        let outcome = await firstFree(
            "nightly", existingBranches: ["nightly-2"], occupiedPaths: ["nightly"]
        )
        #expect(outcome == .free(branch: "nightly-3", destination: URL(fileURLWithPath: "/wts/alas/nightly-3")))
    }

    @Test func reportsExhaustionWhenEveryCandidateIsTaken() async {
        let outcome = await firstFree("nightly", existingBranches: ["nightly", "nightly-2"], limit: 2)
        #expect(outcome == .exhausted)
    }

    /// A host that could not be asked answers neither free nor taken.
    /// Claiming the path anyway risks landing on an existing worktree, so the
    /// candidate run stops rather than guessing.
    @Test func stopsWhenAPathStateCannotBeDetermined() async {
        let outcome = await firstFree("nightly", unknownPaths: ["nightly"])
        #expect(outcome == .undeterminable(URL(fileURLWithPath: "/wts/alas/nightly")))
    }

    /// Suffixing never rescues a name git refuses, so a candidate it would
    /// reject is skipped rather than handed to `git worktree add`.
    @Test func neverProposesANameGitWouldRefuse() async {
        let outcome = await firstFree("night ly")
        #expect(outcome == .exhausted)
    }

    // MARK: - The default probe

    @Test func aLocalDestinationIsReadFromThisMac() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(await ScheduledWorktreeDestination.existence(of: directory, onHost: nil) == .occupied)
        #expect(
            await ScheduledWorktreeDestination.existence(
                of: directory.appendingPathComponent("absent"), onHost: nil
            ) == .free
        )
    }

    /// The bug this guards: a remote project's destination is a path on the
    /// host, and this Mac's filesystem has no standing to answer for it —
    /// not even when a directory happens to sit at the same path here. The
    /// host is unreachable by construction (`.invalid` never resolves), so
    /// the only answers this can give are `unknown` — correct — or
    /// `occupied`, which would mean `FileManager` answered.
    @Test func aRemoteDestinationIsNeverAnsweredByThisMac() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduled-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = await ScheduledWorktreeDestination.existence(of: directory, onHost: "alas-nonexistent.invalid")

        #expect(state == .unknown)
    }
}
