import Foundation
import Testing
@testable import Alas

struct GGInboxModelsTests {
    static let fullSample = #"""
    {"version":1,"total_items":2,
     "buckets":{
       "refresh_failed":[],
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
        let json = #"{"version":1,"total_items":0,"buckets":{"refresh_failed":[],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[],"merged":[{"stack_name":"done","position":1,"sha":"aaa","title":"Shipped","pr_number":7,"pr_url":"https://example.test/7"}]},"stack_errors":[]}"#
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
        #expect(GGInboxBucket.allCases == [.refreshFailed, .readyToLand, .changesRequested, .blockedOnCi, .awaitingReview, .behindBase, .draft])
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

    @Test func decodesRefreshFailedEntryAndNormalizesEmptyURL() throws {
        let json = #"{"version":1,"total_items":1,"buckets":{"refresh_failed":[{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login","pr_number":42,"pr_url":"","ci_status":null,"behind_base":2,"refresh_error":"provider unavailable"}],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[]}"#

        let snapshot = try GGInboxSnapshot.decode(fromJSON: Data(json.utf8))
        let entry = try #require(snapshot.buckets.refreshFailed.first)
        #expect(entry.prUrl == nil)
        #expect(entry.refreshError == "provider unavailable")
        #expect(GGInboxBucket.allCases.first == .refreshFailed)
    }

    @Test func decodesInboxJSONLEvents() throws {
        #expect(try GGInboxEvent.decode(line: #"{"event":"start","total_candidates":2,"total_stack_errors":1,"version":1,"command":"inbox"}"#)
            == .start(totalCandidates: 2, totalStackErrors: 1))

        #expect(try GGInboxEvent.decode(line: #"{"event":"stack_error","stack_name":"stale","error":"missing base","version":1,"command":"inbox"}"#)
            == .stackError(GGInboxStackError(stackName: "stale", error: "missing base")))

        let entry = try GGInboxEvent.decode(line: #"{"event":"entry","completed":1,"total_candidates":2,"included":true,"bucket":"ready_to_land","remote_state":"open","entry":{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login","pr_number":42,"pr_url":"https://example.test/42","ci_status":"success","behind_base":null},"version":1,"command":"inbox"}"#)
        guard case .entry(let payload) = entry else {
            Issue.record("Expected entry event")
            return
        }
        #expect(payload.completed == 1)
        #expect(payload.bucket == .readyToLand)
        #expect(payload.entry.prUrl == "https://example.test/42")

        let failed = try GGInboxEvent.decode(line: #"{"event":"entry_error","completed":2,"total_candidates":2,"included":true,"bucket":"refresh_failed","entry":{"stack_name":"perf","position":2,"sha":"def456","title":"Cache layer","pr_number":43,"behind_base":3},"error":"provider unavailable","version":1,"command":"inbox"}"#)
        guard case .entryError(let payload) = failed else {
            Issue.record("Expected entry_error event")
            return
        }
        #expect(payload.failedEntry.refreshError == "provider unavailable")
        #expect(payload.failedEntry.prUrl == nil)

        let summary = try GGInboxEvent.decode(line: #"{"event":"summary","total_items":0,"buckets":{"refresh_failed":[],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[],"version":1,"command":"inbox"}"#)
        guard case .summary(let snapshot) = summary else {
            Issue.record("Expected summary event")
            return
        }
        #expect(snapshot.totalItems == 0)

        #expect(try GGInboxEvent.decode(line: #"{"version":1,"command":"inbox","status":"error","event":"error","message":"Not in a git repository"}"#)
            == .error(message: "Not in a git repository"))
    }

    @Test(arguments: [
        #"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":2,"command":"inbox"}"#,
        #"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":1,"command":"sync"}"#,
        #"{"event":"future_event","version":1,"command":"inbox"}"#,
        "not json",
    ])
    func rejectsInvalidInboxJSONLEnvelopes(_ line: String) {
        #expect(throws: GGServiceError.self) {
            _ = try GGInboxEvent.decode(line: line)
        }
    }

    @Test func supportsGGVersionZeroNineTwelveAndLater() {
        #expect(GGInboxSupport.isSupported(version: "0.9.12"))
        #expect(GGInboxSupport.isSupported(version: "0.10.0"))
        #expect(!GGInboxSupport.isSupported(version: "0.9.11"))
        #expect(!GGInboxSupport.isSupported(version: nil))
    }

    @Test func insertsInboxEntriesInDisplayOrderAndUpsertsIdentity() {
        var buckets = GGInboxBuckets()
        buckets.insert(GGInboxEntry(stackName: "zebra", position: 1, sha: "aaa", title: "First", prNumber: 1), into: .refreshFailed)
        buckets.insert(GGInboxEntry(stackName: "alpha", position: 2, sha: "bbb", title: "Second", prNumber: 2), into: .refreshFailed)
        buckets.insert(GGInboxEntry(stackName: "alpha", position: 2, sha: "ccc", title: "Updated", prNumber: 2), into: .refreshFailed)

        #expect(buckets.refreshFailed.map(\.stackName) == ["alpha", "zebra"])
        #expect(buckets.refreshFailed.first?.title == "Updated")
    }
}
