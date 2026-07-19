import Foundation
import Testing
@testable import Alas

struct GGActionEventsTests {
    @Test func parsesEachSyncEventVariant() {
        #expect(GGSyncEvent.parse(line: #"{"version":1,"command":"sync","event":"start","total_entries":2}"#)
            == .start(totalEntries: 2))
        #expect(GGSyncEvent.parse(line: #"{"command":"sync","event":"entry_started","position":1,"title":"Add feature"}"#)
            == .entryStarted(position: 1, title: "Add feature"))
        #expect(GGSyncEvent.parse(line: #"{"event":"push_started","position":1}"#)
            == .pushStarted(position: 1))
        #expect(GGSyncEvent.parse(line: #"{"event":"push_done","position":1,"forced":false}"#)
            == .pushDone(position: 1, forced: false))
        #expect(GGSyncEvent.parse(line: #"{"event":"pr_created","position":1,"pr_number":42,"pr_url":"https://x/pull/42","draft":false}"#)
            == .prCreated(position: 1, prNumber: 42, prURL: "https://x/pull/42", draft: false))
        #expect(GGSyncEvent.parse(line: #"{"event":"summary","stack":"s","base":"main","entries":[]}"#)
            == .summary)
        #expect(GGSyncEvent.parse(line: #"{"event":"error","message":"boom"}"#)
            == .error(message: "boom"))
        #expect(GGSyncEvent.parse(line: #"{"event":"push_error","position":1,"message":"push failed"}"#)
            == .error(message: "push failed"))
        #expect(GGSyncEvent.parse(line: #"{"event":"summary","entries":[{"position":2,"error":"PR failed"}]}"#)
            == .error(message: "[2] PR failed"))
        #expect(GGSyncEvent.parse(line: #"{"version":1,"sync":{"entries":[{"position":3,"error":"push failed"}]}}"#)
            == .error(message: "[3] push failed"))
    }

    @Test func skipsBlankUnknownAndMalformedLines() {
        #expect(GGSyncEvent.parse(line: "") == nil)
        #expect(GGSyncEvent.parse(line: "   ") == nil)
        #expect(GGSyncEvent.parse(line: #"{"event":"future_thing","position":9}"#) == nil)
        #expect(GGSyncEvent.parse(line: "not json at all") == nil)
        #expect(GGSyncEvent.parse(line: #"{"no_event_field":true}"#) == nil)
    }

    @Test func decodesLandResult() throws {
        let json = #"{"version":1,"land":{"stack":"s","base":"main","landed":[{"position":1,"pr_number":42},{"position":2,"pr_number":43}]}}"#
        let result = try GGLandResult.decode(fromJSON: Data(json.utf8))
        #expect(result.landed == [
            GGLandedEntry(position: 1, prNumber: 42),
            GGLandedEntry(position: 2, prNumber: 43),
        ])
    }

    @Test func decodesLandResultWithEmptyLanded() throws {
        let json = #"{"version":1,"land":{"stack":"s","base":"main","landed":[]}}"#
        #expect(try GGLandResult.decode(fromJSON: Data(json.utf8)).landed.isEmpty)
    }

    @Test func landDecodeThrowsWhenJSONContainsError() {
        let json = #"{"version":1,"land":{"stack":"s","base":"main","landed":[],"error":"not approved"}}"#
        #expect(throws: GGServiceError.commandFailed(stderr: "not approved")) {
            _ = try GGLandResult.decode(fromJSON: Data(json.utf8))
        }
    }

    @Test func extractsActionErrorMessagesFromNestedJSON() {
        #expect(GGActionErrorMessage.parse(fromJSON: Data(#"{"error":{"message":"top failure"}}"#.utf8)) == "top failure")
        #expect(GGActionErrorMessage.parse(fromJSON: Data(#"{"land":{"error":{"message":"land blocked"}}}"#.utf8)) == "land blocked")
        #expect(GGActionErrorMessage.parse(fromJSON: Data(#"{"sync":{"entries":[{"position":4,"error":{"message":"push blocked"}}]}}"#.utf8)) == "[4] push blocked")
    }

    @Test func landDecodeThrowsMalformedOnGarbage() {
        #expect(throws: GGServiceError.self) {
            _ = try GGLandResult.decode(fromJSON: Data("nonsense".utf8))
        }
    }
}
