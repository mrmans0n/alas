import Foundation
import Testing
import AlasCore
import AlasHostCore

@MainActor // `PeerWorktreeRemoval.run` is main-actor API.
struct PeerWorktreeLifecycleTests {
    nonisolated static func project(host: String? = nil, kind: ProjectKind = .git) -> ProjectSnapshot {
        ProjectSnapshot(ProjectConfig(
            id: "p", name: "repo", path: "/srv/repo", color: "blue", addedAt: .distantPast, host: host, kind: kind
        ))
    }

    nonisolated static func worktree(
        _ branch: String, path: String? = nil, projectID: String = "p", isArchived: Bool = false
    ) -> WorktreeSnapshot {
        let url = URL(fileURLWithPath: path ?? "/srv/\(branch)")
        return WorktreeSnapshot(
            worktree: Worktree(
                id: Worktree.makeId(path: url), projectId: projectID, name: branch, branch: branch,
                path: url, status: .clean, lastActivity: .distantPast, lineageID: "l"
            ),
            operation: nil, isArchived: isArchived
        )
    }

    static func checkout(name: String, memberPath: String) -> WorkspaceCheckoutSnapshot {
        WorkspaceCheckoutSnapshot(
            id: UUID(), workspaceID: UUID(), name: name, executionLocation: .local, branch: "b", rootPath: "/srv/checkout",
            operation: .idle, health: .ready, diagnostics: [],
            members: [WorkspaceAutomationMemberSummary(
                id: UUID(), projectID: "p", name: "repo", worktreePath: memberPath, availability: .available,
                checkpoint: .notStarted
            )]
        )
    }

    @Test func visibleWorktreesJoinProjectsHideArchivedAndMarkMainAndWorkspaceMembers() {
        var state = PeerHostChannel.State(HostSnapshot(
            cursor: HostCursor(generation: UUID(), sequence: 0),
            projects: [Self.project()],
            worktrees: [
                Self.worktree("main", path: "/srv/repo/"),
                Self.worktree("feature"),
                Self.worktree("archived", isArchived: true),
                Self.worktree("member"),
                Self.worktree("orphan", projectID: "gone"),
            ],
            workspaceCheckouts: [], runs: [], sessions: []
        ))
        var archivedCheckout = Self.checkout(name: "Old", memberPath: "/srv/feature")
        archivedCheckout.archivedAt = .distantPast
        state.workspaceCheckouts = [archivedCheckout, Self.checkout(name: "Checkout", memberPath: "/srv/member")]

        let visible = state.visibleWorktrees()
        #expect(visible.map(\.snapshot.worktree.branch) == ["main", "feature", "member"])
        #expect(visible.map(\.isMain) == [true, false, false])
        #expect(visible.map(\.workspaceCheckoutName) == [nil, nil, "Checkout"])
    }

    enum Case: Sendable, CustomTestStringConvertible {
        case plain, main, folder, workspaceMember, remoteProject
        case operation(WorktreeOperation)

        var testDescription: String { String(describing: self) }

        var worktree: PeerHostWorktree {
            let snapshot = PeerWorktreeLifecycleTests.worktree("feature")
            func project(_ host: String? = nil, _ kind: ProjectKind = .git) -> ProjectSnapshot {
                PeerWorktreeLifecycleTests.project(host: host, kind: kind)
            }
            switch self {
            case .plain: return PeerHostWorktree(snapshot: snapshot, project: project(), isMain: false, workspaceCheckoutName: nil)
            case .main: return PeerHostWorktree(snapshot: snapshot, project: project(), isMain: true, workspaceCheckoutName: nil)
            case .folder:
                return PeerHostWorktree(snapshot: snapshot, project: project(nil, .folder), isMain: false, workspaceCheckoutName: nil)
            case .workspaceMember:
                return PeerHostWorktree(snapshot: snapshot, project: project(), isMain: false, workspaceCheckoutName: "W")
            case .remoteProject:
                return PeerHostWorktree(snapshot: snapshot, project: project("build", .git), isMain: false, workspaceCheckoutName: nil)
            case .operation(let operation):
                var held = snapshot
                held.operation = operation
                return PeerHostWorktree(snapshot: held, project: project(), isMain: false, workspaceCheckoutName: nil)
            }
        }
    }

    @Test(arguments: [
        (Case.plain, true, PeerWorktreeControls.available),
        (.plain, false, .hidden), // host without host.worktrees.lifecycle.v1
        (.main, true, .hidden), (.folder, true, .hidden), (.workspaceMember, true, .hidden),
        (.operation(.deleting), true, .hidden), (.operation(.createFailed(message: "x")), true, .hidden),
        (.operation(.deleteFailed(message: "x")), true, .available),
        (.remoteProject, true, .disabled(reason: PeerWorktreeControls.remoteProjectReason)),
    ])
    func controlsFollowTheLocalRules(_ worktree: Case, lifecycleSupported: Bool, expected: PeerWorktreeControls) {
        #expect(worktree.worktree.controls(lifecycleSupported: lifecycleSupported) == expected)
    }

    // MARK: - Removal flow

    nonisolated static let ref = WorktreeRef(projectID: "p", path: "/srv/feature")

    /// Answers requests from `responses` in order, and confirmations from `answers` (true once they run out).
    @MainActor final class Script {
        var responses: [HostResponse]
        var answers: [Bool]
        var requests: [HostRequest] = []
        var confirmations: [PeerWorktreeRemoval.Confirmation] = []

        init(_ responses: [HostResponse], answers: [Bool] = []) {
            self.responses = responses
            self.answers = answers
        }

        func run(_ action: PeerWorktreeRemoval.Action) async -> PeerWorktreeRemoval.Outcome {
            await PeerWorktreeRemoval.run(
                action, on: PeerWorktreeLifecycleTests.worktree("feature"),
                request: { request in
                    self.requests.append(request)
                    return self.responses.removeFirst()
                },
                confirm: { confirmation in
                    self.confirmations.append(confirmation)
                    return self.answers.isEmpty ? true : self.answers.removeFirst()
                }
            )
        }
    }

    static func delete(force: Bool, discard: Bool) -> HostRequest {
        .deleteWorktree(
            worktree: ref, lineageID: "l", branch: "feature", force: force, deleteBranchIfMerged: false,
            discardUnsavedEdits: discard
        )
    }

    @Test func deleteConfirmsThenRetriesWithForceOnlyAfterTheUserAgrees() async {
        let script = Script([.failure(error: .worktreeDeletion(refusal: .needsForce("dirty"))), .done])
        let outcome = await script.run(.delete(keepBranch: true, deleteBranchIfMerged: false))
        #expect(outcome == .done)
        #expect(script.confirmations == [.delete(branch: "feature", keepBranch: true), .force(branch: "feature")])
        #expect(script.requests == [Self.delete(force: false, discard: false), Self.delete(force: true, discard: false)])
    }

    @Test(arguments: [false, true])
    func unsavedEditsAreAskedSeparatelyAndNeverImpliedByForce(archiving: Bool) async {
        if archiving {
            let script = Script([.failure(error: .worktreeArchive(refusal: .unsavedEdits)), .done])
            #expect(await script.run(.archive) == .done)
            #expect(script.confirmations == [.discardUnsavedEdits(branch: "feature", archiving: true)])
            #expect(script.requests == [false, true].map {
                .archiveWorktree(worktree: Self.ref, lineageID: "l", branch: "feature", discardUnsavedEdits: $0)
            })
        } else {
            let script = Script([
                .failure(error: .worktreeDeletion(refusal: .unsavedEdits)),
                .failure(error: .worktreeDeletion(refusal: .needsForce("dirty"))),
                .done,
            ])
            #expect(await script.run(.delete(keepBranch: false, deleteBranchIfMerged: false)) == .done)
            #expect(script.confirmations == [
                .delete(branch: "feature", keepBranch: false),
                .discardUnsavedEdits(branch: "feature", archiving: false),
                .force(branch: "feature"),
            ])
            #expect(script.requests == [
                Self.delete(force: false, discard: false),
                Self.delete(force: false, discard: true),
                Self.delete(force: true, discard: true),
            ])
        }
    }

    @Test(arguments: [false, true])
    func forceIsAskedAtMostOnceAndNeverForAnArchive(archiving: Bool) async {
        let needsForce = HostError.worktreeDeletion(refusal: .needsForce("dirty"))
        let script = Script([.failure(error: needsForce), .failure(error: needsForce)])
        let outcome = await script.run(archiving ? .archive : .delete(keepBranch: false, deleteBranchIfMerged: false))
        #expect(outcome == .refused(message: PeerWorktreeRemoval.message(for: needsForce)))
        #expect(script.confirmations == (archiving ? [] : [.delete(branch: "feature", keepBranch: false), .force(branch: "feature")]))
        #expect(script.requests.count == (archiving ? 1 : 2))
    }

    @Test(arguments: [0, 1])
    func aDeclinedConfirmationSendsNothingMore(declinedAt: Int) async {
        let answers = (0...declinedAt).map { $0 != declinedAt }
        let script = Script([.failure(error: .worktreeDeletion(refusal: .needsForce("dirty"))), .done], answers: answers)
        #expect(await script.run(.delete(keepBranch: false, deleteBranchIfMerged: false)) == .cancelled)
        #expect(script.requests.count == declinedAt) // 0: nothing sent; 1: only the first, unforced request
        #expect(script.requests.allSatisfy { $0 == Self.delete(force: false, discard: false) })
    }

    @Test(arguments: [
        (HostResponse.failure(error: .worktreeDeletion(refusal: .changed("The worktree changed since it was listed."))),
         "The worktree changed since it was listed."),
        (.failure(error: .worktreeDeletion(refusal: .ownedByWorkspaceCheckout("Owned by \u{201C}W\u{201D}."))),
         "Owned by \u{201C}W\u{201D}."),
        (.failure(error: .failed(message: PeerHostChannel.unansweredMessage)), PeerHostChannel.unansweredMessage),
    ])
    func otherRefusalsEndTheFlowWithTheirMessage(_ response: HostResponse, _ message: String) async {
        let script = Script([response])
        #expect(await script.run(.delete(keepBranch: false, deleteBranchIfMerged: false)) == .refused(message: message))
        #expect(script.requests.count == 1)
        #expect(script.confirmations == [.delete(branch: "feature", keepBranch: false)]) // no force prompt
    }
}
