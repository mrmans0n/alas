import Foundation
import Testing
@testable import Alas

struct GGLandingPresentationTests {
    @Test func readinessCombinesAvailableFacts() {
        #expect(GGLandingPresentation.detail(for: wait(ci: "running", approved: true))
            == "CI running · Approved · Waiting 20s")
        #expect(GGLandingPresentation.detail(for: wait(approved: false))
            == "Waiting for approval · Waiting 20s")
        #expect(GGLandingPresentation.detail(for: wait(ci: "success"))
            == "CI passed · Waiting 20s")
        #expect(GGLandingPresentation.detail(for: wait(ci: "failure"))
            == "CI failed · Waiting 20s")
        #expect(GGLandingPresentation.detail(for: wait()) == "Waiting for readiness · Waiting 20s")
    }

    @Test func mergeTrainIncludesQueuePosition() {
        let wait = GGLandWait(
            position: 1, prNumber: 42, phase: .mergeTrain, poll: 4,
            elapsedSeconds: 65, ciStatus: nil, approved: nil,
            mergeTrainStatus: "fresh", mergeTrainPosition: 3,
            pipelineRunning: true, error: nil
        )
        #expect(GGLandingPresentation.detail(for: wait)
            == "Merge train · Position 3 · Pipeline running · Waiting 1m 5s")
    }

    @Test func queuedIsDistinctFromMergedAndSummaryCountsBoth() {
        var session = session()
        session.rows[0].outcome = .init(position: 1, prNumber: 41, action: "merged")
        session.rows[1].outcome = .init(position: 2, prNumber: 42, action: "queued")
        #expect(GGLandingPresentation.detail(for: session.rows[1], in: session) == "Queued")
        #expect(GGLandingPresentation.progress(for: session) == "2 / 3")
        session.phase = .succeeded
        session.result = .init(landed: session.rows.compactMap(\.outcome), remaining: 1)
        #expect(GGLandingPresentation.summary(for: session) == "1 merged · 1 queued · 1 remaining")
    }

    @Test func terminalStatesPreservePartialProgress() {
        var session = session()
        session.rows[0].outcome = .init(position: 1, prNumber: 41, action: "merged")
        session.phase = .cancelled
        #expect(GGLandingPresentation.summary(for: session) == "Cancelled · 1 merged · 2 remaining")
        #expect(GGLandingPresentation.detail(for: session.rows[1], in: session) == "Cancelled")
        session.phase = .failed
        session.error = "Merge failed"
        session.rows[1].outcome = .init(position: 2, prNumber: 42, error: "Conflict")
        #expect(GGLandingPresentation.summary(for: session) == "Failed · 1 merged · 2 remaining")
        #expect(GGLandingPresentation.detail(for: session.rows[1], in: session) == "Conflict")
        #expect(GGLandingPresentation.detail(for: session.rows[2], in: session) == "Not landed")
        #expect(GGLandingPresentation.progress(for: session) == "1 / 3")
    }

    @Test func onlyActiveRowsShowHeartbeatWhileRunning() {
        var session = session()
        session.activeWait = wait()
        session.rows[0].wait = wait()
        #expect(GGLandingPresentation.isActive(session.rows[0], in: session))
        #expect(!GGLandingPresentation.isActive(session.rows[1], in: session))
        session.phase = .cancelled
        #expect(!GGLandingPresentation.isActive(session.rows[0], in: session))
        #expect(GGLandingPresentation.detail(for: session.rows[0], in: session) == "Cancelled")
    }

    private func wait(ci: String? = nil, approved: Bool? = nil) -> GGLandWait {
        .init(position: 1, prNumber: 42, phase: .readiness, poll: 2,
              elapsedSeconds: 20, ciStatus: ci, approved: approved,
              mergeTrainStatus: nil, mergeTrainPosition: nil, pipelineRunning: nil, error: nil)
    }

    private func session() -> GGLandingSession {
        .init(id: UUID(), projectId: "p", worktreeId: "w", stack: "feature", base: "main",
              target: "c3", startedAt: Date(), rows: (1...3).map {
                  .init(position: $0, title: "Change \($0)", ggId: "c\($0)", prNumber: 40 + $0)
              }, phase: .running, activeWait: nil, warning: nil, result: nil, error: nil)
    }
}
