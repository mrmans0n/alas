import Foundation
import Testing
@testable import Alas

struct GGLandingPresentationTests {
    @Test func preparationSpinsForSessionButNotAnEntry() {
        var session = session()
        session.isPreparing = true
        #expect(GGLandingPresentation.status(for: session) == .checking)
        #expect(GGLandingPresentation.status(for: session).isSpinning)
        #expect(session.rows.allSatisfy { !GGLandingPresentation.isActive($0, in: session) })
        session.isPreparing = false
        #expect(GGLandingPresentation.rowStatus(for: session.rows[0], in: session) == .active)
        #expect(GGLandingPresentation.rowStatus(for: session.rows[1], in: session) == .pending)
    }

    @Test(arguments: [GGLandPhase.readiness, .mergeTrain])
    func waitSelectsOnlyItsUnfinishedEntry(phase: GGLandPhase) {
        var session = session()
        let wait = wait(position: 2, phase: phase)
        session.activeWait = wait
        session.rows[1].wait = wait
        #expect(GGLandingPresentation.status(for: session) == (phase == .readiness ? .readiness : .mergeTrain))
        #expect(!GGLandingPresentation.isActive(session.rows[0], in: session))
        #expect(GGLandingPresentation.isActive(session.rows[1], in: session))
        session.rows[1].outcome = .init(position: 2, prNumber: 42, action: "queued")
        #expect(!GGLandingPresentation.isActive(session.rows[1], in: session))
        #expect(GGLandingPresentation.rowStatus(for: session.rows[1], in: session) == .queued)
    }

    @Test(arguments: [GGLandingPhase.cancelling, .cancelled, .failed, .succeeded])
    func sessionPhaseOverridesStaleWaitAndPreparation(phase: GGLandingPhase) {
        var session = session()
        session.phase = phase
        session.isPreparing = true
        session.activeWait = wait()
        session.rows[0].wait = wait()
        let expected: GGLandingPresentation.Status
        switch phase {
        case .cancelling: expected = .cancelling
        case .cancelled: expected = .cancelled
        case .failed: expected = .failed
        default: expected = .merged
        }
        let status = GGLandingPresentation.status(for: session)
        #expect(status == expected)
        #expect(status.isSpinning == (phase == .cancelling))
        if phase != .cancelling {
            #expect(session.rows.allSatisfy { !GGLandingPresentation.isActive($0, in: session) })
        }
    }

    @Test func partialResultsKeepQueuedMergedAndFailedSeparate() {
        var session = session()
        session.rows[0].outcome = .init(position: 1, prNumber: 41, action: "merged")
        session.rows[1].outcome = .init(position: 2, prNumber: 42, action: "queued")
        session.rows[2].outcome = .init(position: 3, prNumber: 43, error: "Conflict")
        session.phase = .failed
        #expect(GGLandingPresentation.counts(for: session) == .init(total: 3, completed: 2, merged: 1, queued: 1, remaining: 1))
        #expect(GGLandingPresentation.rowStatus(for: session.rows[0], in: session) == .merged)
        #expect(GGLandingPresentation.rowStatus(for: session.rows[1], in: session) == .queued)
        #expect(GGLandingPresentation.rowStatus(for: session.rows[2], in: session) == .failed)
        session.rows[2].outcome = .init(position: 3, prNumber: 43, action: "merged")
        session.phase = .succeeded
        session.result = .init(landed: session.rows.compactMap(\.outcome), remaining: 0)
        #expect(GGLandingPresentation.status(for: session) == .queued)
        #expect(GGLandingPresentation.counts(for: session).remaining == 0)
    }

    @Test(arguments: ["queued", "already_queued"])
    func queuedEntriesNeverAppearMerged(action: String) {
        var session = session()
        for index in session.rows.indices {
            session.rows[index].outcome = .init(
                position: session.rows[index].position,
                prNumber: session.rows[index].prNumber,
                action: action
            )
        }
        session.phase = .succeeded
        session.result = .init(landed: session.rows.compactMap(\.outcome), remaining: 0)
        #expect(GGLandingPresentation.counts(for: session) == .init(total: 3, completed: 3, merged: 0, queued: 3, remaining: 0))
        #expect(GGLandingPresentation.status(for: session) == .queued)
        #expect(session.rows.allSatisfy { GGLandingPresentation.rowStatus(for: $0, in: session) == .queued })
    }

    @Test func terminalDiagnosticsKeepBothSessionAndResultInformation() {
        var session = session()
        session.phase = .failed
        session.warning = "Temporary forge outage"
        session.error = "Landing stopped"
        session.result = .init(landed: [], warnings: ["Cleanup skipped"], error: "Merge rejected")
        #expect(Set(GGLandingPresentation.warnings(for: session)) == ["Temporary forge outage", "Cleanup skipped"])
        #expect(Set(GGLandingPresentation.errors(for: session)) == ["Landing stopped", "Merge rejected"])
    }

    @Test(arguments: [GGLandingPhase.running, .cancelling, .cancelled, .failed, .succeeded])
    func sidebarSuppressesSuccessAndKeepsTerminalPrecedence(phase: GGLandingPhase) throws {
        var session = session()
        session.isPreparing = true
        session.activeWait = wait()
        session.phase = phase
        let status = GGLandingPresentation.sidebarStatus(for: session)
        if phase == .succeeded {
            #expect(status == nil)
        } else {
            let status = try #require(status)
            #expect(status.isSpinning == (phase == .running || phase == .cancelling))
            if phase == .failed { #expect(status.colorToken == "del") }
        }
    }

    private func wait(position: Int = 1, phase: GGLandPhase = .readiness) -> GGLandWait {
        .init(position: position, prNumber: 40 + position, phase: phase, poll: 2,
              elapsedSeconds: 20, ciStatus: "running", approved: false,
              mergeTrainStatus: nil, mergeTrainPosition: nil, pipelineRunning: nil, error: nil)
    }

    private func session() -> GGLandingSession {
        .init(id: UUID(), projectId: "p", worktreeId: "w", stack: "feature", base: "main",
              target: "c3", confirmedScope: .init(
                  projectId: "p", worktreeId: "w", stack: "feature", base: "main", target: "c3", rows: []
              ), startedAt: Date(), rows: (1...3).map {
                  .init(position: $0, title: "Change \($0)", ggId: "c\($0)", prNumber: 40 + $0)
              }, phase: .running, activeWait: nil, warning: nil, result: nil, error: nil, completedIDs: [])
    }
}
