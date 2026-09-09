import Testing
@testable import Alas

struct GGLandEventTests {
    @Test func decodesStartAndReadinessWait() throws {
        #expect(try GGLandEvent.decode(line: #"{"version":1,"command":"land","status":"ok","event":"start","stack":"feature","base":"main","total_entries":2}"#)
            == .start(stack: "feature", base: "main", totalEntries: 2))
        #expect(try GGLandEvent.decode(line: #"{"version":1,"command":"land","status":"ok","event":"wait","position":1,"pr_number":42,"phase":"readiness","poll":3,"elapsed_seconds":20,"ci_status":"running","approved":true,"merge_train_status":null,"merge_train_position":null,"pipeline_running":null,"error":null}"#)
            == .wait(GGLandWait(
                position: 1, prNumber: 42, phase: .readiness, poll: 3,
                elapsedSeconds: 20, ciStatus: "running", approved: true,
                mergeTrainStatus: nil, mergeTrainPosition: nil,
                pipelineRunning: nil, error: nil
            )))
    }

    @Test func decodesEntrySummaryAndFatalError() throws {
        #expect(try GGLandEvent.decode(line: #"{"version":1,"command":"land","status":"ok","event":"entry","position":1,"sha":"abc1234","title":"First","gg_id":"c-abc","pr_number":42,"action":"merged","error":null}"#)
            == .entry(GGLandedEntry(
                position: 1, sha: "abc1234", title: "First", ggId: "c-abc",
                prNumber: 42, action: "merged", error: nil
            )))

        guard case .summary(let summary) = try GGLandEvent.decode(line: #"{"version":1,"command":"land","status":"warning","event":"summary","stack":"feature","base":"main","landed":[],"remaining":1,"cleaned":false,"warnings":["cleanup skipped"],"error":"CI failed"}"#) else {
            Issue.record("Expected summary")
            return
        }
        #expect(summary.remaining == 1)
        #expect(summary.warnings == ["cleanup skipped"])
        #expect(summary.error == "CI failed")

        #expect(try GGLandEvent.decode(line: #"{"version":1,"command":"land","status":"error","event":"error","message":"Not in a repository"}"#)
            == .error(message: "Not in a repository"))
    }

    @Test func rejectsWrongVersionCommandAndUnknownEvent() {
        #expect(throws: GGServiceError.unsupportedSchema(2)) {
            _ = try GGLandEvent.decode(line: #"{"version":2,"command":"land","event":"start","stack":"s","base":"main","total_entries":1}"#)
        }
        #expect(throws: GGServiceError.self) {
            _ = try GGLandEvent.decode(line: #"{"version":1,"command":"sync","event":"start","stack":"s","base":"main","total_entries":1}"#)
        }
        #expect(throws: GGServiceError.self) {
            _ = try GGLandEvent.decode(line: #"{"version":1,"command":"land","event":"mystery"}"#)
        }
    }
}
