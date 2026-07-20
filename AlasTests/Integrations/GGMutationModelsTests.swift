import Foundation
import Testing
@testable import Alas

struct GGMutationModelsTests {
    @Test func splitPlanEncodesProtocolV1SnakeCasePayload() throws {
        let plan = GGSplitPlan(
            version: 1,
            planToken: "token",
            target: GGSplitTargetIdentity(ggID: "change-2", sha: "abc", tree: "tree"),
            selectedHunkIDs: ["h-1"],
            firstMessage: "First",
            remainderMessage: "Remainder"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(plan)) as? [String: Any]
        )

        #expect(object["version"] as? Int == 1)
        #expect(object["plan_token"] as? String == "token")
        #expect(object["selected_hunk_ids"] as? [String] == ["h-1"])
        #expect((object["target"] as? [String: Any])?["gg_id"] as? String == "change-2")
    }

    @Test func operationSummaryNormalizesCommittedWireStatusToCompleted() throws {
        let data = Data(#"{"id":"op_1","kind":"split","status":"committed","created_at_ms":42,"args":["split"],"touched_remote":false,"is_undoable":true,"is_undo":false}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let summary = try decoder.decode(GGOperationSummary.self, from: data)

        #expect(summary.status == .completed)
        #expect(summary.kind == "split")
        #expect(summary.createdAtMs == 42)
        #expect(summary.undoes == nil)
    }

    @Test func splitDescriptionRoundTripsAllProtocolFields() throws {
        let value = GGSplitDescription(
            version: 1,
            planToken: "token",
            target: GGSplitTargetIdentity(ggID: nil, sha: "abc", tree: "tree"),
            hunks: [GGSplitHunk(id: "h-1", path: "A.swift", header: "@@ -1 +1 @@", patch: "-a\n+b\n")],
            nonTextualFiles: ["image.png"],
            firstMessage: "First",
            remainderMessage: "Remainder"
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let decoded = try decoder.decode(GGSplitDescription.self, from: encoder.encode(value))

        #expect(decoded == value)
    }
}
