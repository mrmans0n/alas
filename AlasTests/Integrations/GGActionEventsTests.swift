import Foundation
import Testing
@testable import Alas

struct GGActionEventsTests {
    @Test func everyMutationRequestMapsToItsPresentationAction() {
        let splitTarget = GGSplitTargetIdentity(ggID: "change-1", sha: "abc", tree: "tree")
        let requests: [(GGMutationRequest, GGStackActionKind)] = [
            (.amendCurrent, .amendCurrent),
            (.absorbStaged, .absorbStaged),
            (.checkout(target: "change-1"), .checkout),
            (.drop(target: "change-1"), .drop),
            (.unstack(target: "change-1", name: "upper", createWorktree: true), .unstack),
            (.reorder(order: ["change-1"]), .reorder),
            (.restack, .restack),
            (.rebase(target: "main"), .rebase),
            (.sync, .sync),
            (.land(target: "change-1"), .land),
            (.clean, .clean),
            (.continueOperation, .continueOp),
            (.abortOperation, .abortOp),
            (.undo(operationID: "op_1"), .undo),
            (.applySplit(planURL: URL(fileURLWithPath: "/tmp/plan"), target: splitTarget, planToken: "token"), .split),
        ]

        for (request, action) in requests {
            #expect(request.actionKind == action)
        }
    }

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
        #expect(GGSyncEvent.parse(line: #"{"event":"pr_updated","position":1,"pr_number":42,"action":"updated"}"#)
            == .prUpdated(position: 1, prNumber: 42, action: "updated"))
        #expect(GGSyncEvent.parse(line: #"{"event":"pr_skipped_closed","position":2,"pr_number":43}"#)
            == .prSkippedClosed(position: 2, prNumber: 43))
        #expect(GGSyncEvent.parse(line: #"{"event":"summary","stack":"s","base":"main","entries":[]}"#)
            == .summary)
        #expect(GGSyncEvent.parse(line: #"{"event":"error","message":"boom"}"#)
            == .error(position: nil, operation: nil, message: "boom"))
        #expect(GGSyncEvent.parse(line: #"{"event":"push_error","position":1,"message":"push failed"}"#)
            == .error(position: 1, operation: "push", message: "push failed"))
        #expect(GGSyncEvent.parse(line: #"{"event":"summary","entries":[{"position":2,"error":"PR failed"}]}"#)
            == .error(position: 2, operation: nil, message: "PR failed"))
        #expect(GGSyncEvent.parse(line: #"{"version":1,"sync":{"entries":[{"position":3,"error":"push failed"}]}}"#)
            == .error(position: 3, operation: nil, message: "push failed"))
    }

    @Test func skipsBlankUnknownAndMalformedLines() {
        #expect(GGSyncEvent.parse(line: "") == nil)
        #expect(GGSyncEvent.parse(line: "   ") == nil)
        #expect(GGSyncEvent.parse(line: #"{"event":"future_thing","position":9}"#) == nil)
        #expect(GGSyncEvent.parse(line: "not json at all") == nil)
        #expect(GGSyncEvent.parse(line: #"{"no_event_field":true}"#) == nil)
    }

    @Test func summaryEnvelopePreservesEveryEntryErrorAndTerminalIdentity() {
        let line = #"{"event":"summary","entries":[{"position":1,"error":"push failed"},{"position":2,"error":{"message":"PR failed"}}]}"#

        #expect(GGSyncEvent.parseEvents(line: line) == [
            .error(position: 1, operation: nil, message: "push failed"),
            .error(position: 2, operation: nil, message: "PR failed"),
            .summary,
        ])
    }

    @Test func decodesLandResult() throws {
        let json = #"{"version":1,"land":{"stack":"s","base":"main","landed":[{"position":1,"pr_number":42},{"position":2,"pr_number":43}]}}"#
        let result = try GGLandResult.decode(fromJSON: Data(json.utf8))
        #expect(result.landed == [
            GGLandedEntry(position: 1, prNumber: 42),
            GGLandedEntry(position: 2, prNumber: 43),
        ])
    }

    @Test func decodesLandResultActions() throws {
        let json = #"{"version":1,"land":{"stack":"s","base":"main","landed":[{"position":1,"pr_number":42,"action":"merged"},{"position":2,"pr_number":43,"action":"queued"}]}}"#
        let result = try GGLandResult.decode(fromJSON: Data(json.utf8))
        #expect(result.landed.map(\.action) == ["merged", "queued"])
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

    @Test func extractsErrorsFromMutationResponseEnvelopes() {
        for command in ["clean", "drop", "unstack", "restack", "split"] {
            let json = #"{"\#(command)":{"error":{"message":"\#(command) blocked"}}}"#
            #expect(
                GGActionErrorMessage.parse(fromJSON: Data(json.utf8)) == "\(command) blocked",
                "Failed to parse the \(command) error envelope."
            )
        }

        #expect(
            GGActionErrorMessage.parse(
                fromJSON: Data(#"{"metadata":{"error":{"message":"diagnostic only"}}}"#.utf8)
            ) == nil
        )
    }

    @Test func landDecodeThrowsMalformedOnGarbage() {
        #expect(throws: GGServiceError.self) {
            _ = try GGLandResult.decode(fromJSON: Data("nonsense".utf8))
        }
    }
}
