import Foundation
import Testing
@testable import Alas

@Suite("GatekeeperRemediator")
@MainActor
struct GatekeeperRemediatorTests {
    /// Test double recording the orchestration: which steps ran and how
    /// many times. xattr success and reassess result are scripted per
    /// test.
    @MainActor
    final class Recorder {
        var steps: [String] = []
        var xattrCalls = 0
        var invalidations = 0
        var xattrOutcome = true
        var reassessResult: GatekeeperAssessor.Result = .rejected
    }

    private func makeRemediator(recorder: Recorder) -> GatekeeperRemediator {
        GatekeeperRemediator(
            removeQuarantine: { _ in
                recorder.xattrCalls += 1
                recorder.steps.append("xattr")
                return recorder.xattrOutcome
            },
            reassess: { _ in
                recorder.steps.append("assess")
                return recorder.reassessResult
            },
            invalidate: { _ in
                recorder.invalidations += 1
                recorder.steps.append("invalidate")
            }
        )
    }

    @Test("xattr removal unblocks the binary")
    func xattrUnblocks() async {
        let recorder = Recorder()
        recorder.reassessResult = .allowed
        let remediator = makeRemediator(recorder: recorder)

        let outcome = await remediator.remediate(realPath: "/opt/homebrew/bin/gopls")

        #expect(outcome == .allowed)
        #expect(recorder.xattrCalls == 1)
        #expect(recorder.invalidations == 1)
        #expect(recorder.steps == ["xattr", "invalidate", "assess"])
    }

    @Test("xattr removed but binary still rejected → stillBlocked")
    func stillBlockedAfterXattr() async {
        let recorder = Recorder()
        recorder.xattrOutcome = true
        recorder.reassessResult = .rejected
        let remediator = makeRemediator(recorder: recorder)

        let outcome = await remediator.remediate(realPath: "/opt/homebrew/bin/gopls")

        #expect(outcome == .stillBlocked)
    }

    @Test("xattr removal failed → failed outcome")
    func xattrFailedSurfacesFailure() async {
        let recorder = Recorder()
        recorder.xattrOutcome = false
        recorder.reassessResult = .rejected
        let remediator = makeRemediator(recorder: recorder)

        let outcome = await remediator.remediate(realPath: "/opt/homebrew/bin/gopls")

        if case .failed = outcome {
            // expected
        } else {
            Issue.record("expected .failed, got \(outcome)")
        }
    }

    @Test(".unknown reassessment after a removal is treated as still blocked")
    func unknownReassessIsStillBlocked() async {
        // The remediator can't claim success on an indeterminate signal —
        // safer to keep the banner and tell the user something's still
        // off than to hide it on a partial answer.
        let recorder = Recorder()
        recorder.reassessResult = .unknown
        let remediator = makeRemediator(recorder: recorder)

        let outcome = await remediator.remediate(realPath: "/opt/homebrew/bin/gopls")

        #expect(outcome == .stillBlocked)
    }
}
