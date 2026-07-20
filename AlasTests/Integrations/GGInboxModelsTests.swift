import Foundation
import Testing
@testable import Alas

struct GGInboxModelsTests {
    static let fullSample = #"""
    {"version":1,"total_items":2,
     "buckets":{
       "ready_to_land":[{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login flow","pr_number":42,"pr_url":"https://example.test/42","ci_status":"passed","behind_base":2}],
       "changes_requested":[],
       "blocked_on_ci":[],
       "awaiting_review":[{"stack_name":"perf","position":2,"sha":"def456","title":"Cache layer","pr_number":43,"pr_url":"https://example.test/43"}],
       "behind_base":[],
       "draft":[]},
     "stack_errors":[{"stack_name":"broken","error":"stack branch missing"}]}
    """#

    @Test func decodesFullSample() throws {
        let snapshot = try GGInboxSnapshot.decode(fromJSON: Data(Self.fullSample.utf8))
        #expect(snapshot.version == 1)
        #expect(snapshot.totalItems == 2)
        let ready = snapshot.buckets.readyToLand
        #expect(ready.count == 1)
        #expect(ready[0].stackName == "auth")
        #expect(ready[0].prNumber == 42)
        #expect(ready[0].ciStatus == "passed")
        #expect(ready[0].behindBase == 2)
        // Optional fields absent → nil.
        let awaiting = snapshot.buckets.awaitingReview
        #expect(awaiting[0].ciStatus == nil)
        #expect(awaiting[0].behindBase == nil)
        // merged absent (no --all) → empty, not a decode failure.
        #expect(snapshot.buckets.merged.isEmpty)
        #expect(snapshot.stackErrors == [GGInboxStackError(stackName: "broken", error: "stack branch missing")])
    }

    @Test func decodesMergedBucketWhenPresent() throws {
        let json = #"{"version":1,"total_items":0,"buckets":{"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[],"merged":[{"stack_name":"done","position":1,"sha":"aaa","title":"Shipped","pr_number":7,"pr_url":"https://example.test/7"}]},"stack_errors":[]}"#
        let snapshot = try GGInboxSnapshot.decode(fromJSON: Data(json.utf8))
        #expect(snapshot.buckets.merged.count == 1)
    }

    @Test func malformedJSONThrowsMalformedOutput() {
        #expect(throws: GGServiceError.self) {
            _ = try GGInboxSnapshot.decode(fromJSON: Data("not json".utf8))
        }
        #expect(throws: GGServiceError.self) {
            _ = try GGInboxSnapshot.decode(fromJSON: Data(#"{"version":1}"#.utf8))
        }
    }

    @Test func bucketMetadataPriorityOrderAndAccessors() throws {
        #expect(GGInboxBucket.allCases == [.readyToLand, .changesRequested, .blockedOnCi, .awaitingReview, .behindBase, .draft])
        #expect(GGInboxBucket.readyToLand.title == "Ready to land")
        #expect(GGInboxBucket.readyToLand.themeToken == "add")
        #expect(GGInboxBucket.changesRequested.themeToken == "warn")
        #expect(GGInboxBucket.blockedOnCi.themeToken == "warn")
        #expect(GGInboxBucket.draft.themeToken == "fg-dim")
        let snapshot = try GGInboxSnapshot.decode(fromJSON: Data(Self.fullSample.utf8))
        #expect(GGInboxBucket.readyToLand.entries(in: snapshot.buckets).count == 1)
        #expect(GGInboxBucket.awaitingReview.entries(in: snapshot.buckets).count == 1)
        #expect(GGInboxBucket.draft.entries(in: snapshot.buckets).isEmpty)
    }
}
