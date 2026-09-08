import Foundation
import Testing
@testable import Alas

struct AlasCLIRequestTests {
    @Test func decodeOpenRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt","/tmp/b.txt"]}"#

        let request = try AlasCLIRequest.decode(from: Data(json.utf8))

        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: ["/tmp/a.txt", "/tmp/b.txt"])))
    }

    @Test func decodesOpenLineRangeRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"],"params":{"line":12,"end_line":15}}"#

        let request = try AlasCLIRequest.decode(from: Data(json.utf8))

        #expect(request.command == .openAt(path: "/tmp/a.txt", line: 12, endLine: 15))
    }

    @Test func decodesOpenSingleLineRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"],"params":{"line":12}}"#

        let request = try AlasCLIRequest.decode(from: Data(json.utf8))

        #expect(request.command == .openAt(path: "/tmp/a.txt", line: 12, endLine: nil))
    }

    @Test func rejectsInvalidOpenLineRanges() throws {
        let missingStart = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"],"params":{"end_line":15}}"#
        let reversed = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt"],"params":{"line":15,"end_line":12}}"#
        let multiple = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt","/tmp/b.txt"],"params":{"line":12}}"#

        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(missingStart.utf8))
        }
        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(reversed.utf8))
        }
        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(multiple.utf8))
        }
    }

    @Test func decodesWorktreeListRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"wt","subcommand":"list","session_id":"s1"}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.list)))
    }

    @Test func decodesWorktreeSwitchRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"wt","subcommand":"switch","session_id":"s1","target":"feature/review"}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.switch(target: "feature/review"))))
    }

    @Test func decodesWorktreeNewRequestWithBase() throws {
        let json = #"{"v":1,"kind":"cli","command":"wt","subcommand":"new","session_id":"s1","branch":"feature/review","base":"main"}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.new(branch: "feature/review", base: "main"))))
    }

    @Test func decodesWorktreeDeleteRequestWithFlags() throws {
        let json = #"{"v":1,"kind":"cli","command":"wt","subcommand":"delete","session_id":"s1","target":"feature/review","force":true,"keep_branch":true}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .worktree(.delete(target: "feature/review", force: true, keepBranch: true))))
    }

    @Test func decodesLocalReviewRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"review","session_id":"s1"}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges(worktree: nil))))
    }

    @Test func decodesProviderReviewRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"review","session_id":"s1","target":"123"}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .review(.target("123", worktree: nil))))
    }

    @Test func reviewDecodesWorktreeParam() throws {
        let json = #"{"v":1,"kind":"cli","command":"review","session_id":"s1","target":"main..HEAD","params":{"worktree":"feature-x"}}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request.command == .review(.target("main..HEAD", worktree: "feature-x")))
    }

    @Test func reviewLocalChangesDecodesWorktreeParam() throws {
        let json = #"{"v":1,"kind":"cli","command":"review","session_id":"s1","params":{"worktree":"feature-x"}}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request.command == .review(.localChanges(worktree: "feature-x")))
    }

    @Test func rejectsMissingWorktreeTarget() throws {
        let json = #"{"v":1,"kind":"cli","command":"wt","subcommand":"switch","session_id":"s1"}"#
        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func rejectsNonCLIKind() throws {
        let json = #"{"v":1,"event":"busy","agent":"claude","session_id":"s1"}"#

        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func rejectsEmptyPathsForOpen() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":[]}"#

        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func rejectsRelativePathsForOpen() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["relative.txt"]}"#

        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func decodesOpenRequestByCwdWithoutSession() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","cwd":"/repo","paths":["/repo/a.txt"]}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request.sessionId == nil)
        #expect(request.cwd == "/repo")
        #expect(request.command == .open(paths: ["/repo/a.txt"]))
    }

    @Test func decodesNotifyRequestWithDefaults() throws {
        let json = #"{"v":1,"kind":"cli","command":"notify","session_id":"s1","params":{"body":"Done, take a look"}}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request.command == .notify(body: "Done, take a look", title: nil, level: .attention))
    }

    @Test func decodesNotifyRequestWithTitleAndInfoLevel() throws {
        let json = #"{"v":1,"kind":"cli","command":"notify","session_id":"s1","params":{"body":"Background task finished","title":"Done","level":"info"}}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request.command == .notify(body: "Background task finished", title: "Done", level: .info))
    }

    @Test func decodesSessionOrchestrationRequests() throws {
        let list = #"{"v":1,"kind":"cli","command":"session_list","session_id":"s1","future_transport_field":true,"params":{"future_param":true}}"#
        #expect(try AlasCLIRequest.decode(from: Data(list.utf8)).command == .sessionList)

        let current = #"{"v":1,"kind":"cli","command":"session_new","session_id":"s1","params":{"prompt":"Task"}}"#
        #expect(try AlasCLIRequest.decode(from: Data(current.utf8)).command == .sessionNew(
            prompt: "Task", agentID: nil, worktree: .current
        ))

        let existing = #"{"v":1,"kind":"cli","command":"session_new","session_id":"s1","params":{"prompt":"Task","agent":"codex","worktree":"feature"}}"#
        #expect(try AlasCLIRequest.decode(from: Data(existing.utf8)).command == .sessionNew(
            prompt: "Task", agentID: "codex", worktree: .existing(worktreeID: "feature")
        ))

        let fresh = #"{"v":1,"kind":"cli","command":"session_new","session_id":"s1","params":{"prompt":"Task","new_worktree":{"branch":"child","base":"origin/main"}}}"#
        #expect(try AlasCLIRequest.decode(from: Data(fresh.utf8)).command == .sessionNew(
            prompt: "Task", agentID: nil, worktree: .new(branch: "child", base: "origin/main")
        ))

        let send = #"{"v":1,"kind":"cli","command":"session_send","session_id":"s1","params":{"session_id":"child","prompt":"Follow up"}}"#
        #expect(try AlasCLIRequest.decode(from: Data(send.utf8)).command == .sessionSend(
            sessionID: "child", prompt: "Follow up"
        ))
    }

    @Test func decodesWorkspaceAutomationRequests() throws {
        let checkoutID = UUID()
        let memberID = UUID()

        let list = #"{"v":1,"kind":"cli","command":"workspace","subcommand":"list","cwd":"/repo"}"#
        #expect(try AlasCLIRequest.decode(from: Data(list.utf8)).command == .workspace(.list))

        let show = #"{"v":1,"kind":"cli","command":"workspace","subcommand":"show","cwd":"/repo","params":{"checkout_id":"\#(checkoutID.uuidString)"}}"#
        #expect(try AlasCLIRequest.decode(from: Data(show.utf8)).command == .workspace(.show(checkoutID: checkoutID)))

        let switchRequest = #"{"v":1,"kind":"cli","command":"workspace","subcommand":"switch","cwd":"/repo","params":{"checkout_id":"\#(checkoutID.uuidString)"}}"#
        #expect(try AlasCLIRequest.decode(from: Data(switchRequest.utf8)).command == .workspace(.switch(checkoutID: checkoutID)))

        let focus = #"{"v":1,"kind":"cli","command":"workspace","subcommand":"focus","cwd":"/repo","params":{"checkout_id":"\#(checkoutID.uuidString)","member_id":"\#(memberID.uuidString)"}}"#
        #expect(try AlasCLIRequest.decode(from: Data(focus.utf8)).command == .workspace(.focus(checkoutID: checkoutID, memberID: memberID)))
    }

    @Test func rejectsInvalidSessionOrchestrationRequests() throws {
        for invalid in [
            #"{"v":1,"kind":"cli","command":"session_list","session_id":"s1"}"#,
            #"{"v":1,"kind":"cli","command":"session_new","session_id":"s1","params":{"prompt":"   "}}"#,
            #"{"v":1,"kind":"cli","command":"session_new","session_id":"s1","params":{"prompt":"Task","agent":"  "}}"#,
            #"{"v":1,"kind":"cli","command":"session_new","session_id":"s1","params":{"prompt":"Task","worktree":"  "}}"#,
            #"{"v":1,"kind":"cli","command":"session_new","session_id":"s1","params":{"prompt":"Task","worktree":"feature","new_worktree":{"branch":"child"}}}"#,
            #"{"v":1,"kind":"cli","command":"session_new","session_id":"s1","params":{"prompt":"Task","new_worktree":{"branch":"  "}}}"#,
            #"{"v":1,"kind":"cli","command":"session_send","session_id":"s1","params":{"session_id":"child","prompt":3}}"#,
        ] {
            #expect(throws: AlasCLIRequestError.malformed, "should reject: \(invalid)") {
                try AlasCLIRequest.decode(from: Data(invalid.utf8))
            }
        }
    }

    @Test func rejectsInvalidNotifyRequests() throws {
        for bad in [
            #"{"v":1,"kind":"cli","command":"notify","session_id":"s1"}"#,
            #"{"v":1,"kind":"cli","command":"notify","session_id":"s1","params":{"body":"   "}}"#,
            #"{"v":1,"kind":"cli","command":"notify","session_id":"s1","params":{"body":"Done","level":"urgent"}}"#,
        ] {
            #expect(throws: AlasCLIRequestError.self, "should reject: \(bad)") {
                try AlasCLIRequest.decode(from: Data(bad.utf8))
            }
        }
    }

    @Test func decodesResolveRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"resolve","cwd":"/repo"}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request.command == .resolve)
        #expect(request.cwd == "/repo")
    }

    @Test func rejectsRequestWithNeitherSessionNorCwd() throws {
        let json = #"{"v":1,"kind":"cli","command":"wt","subcommand":"list"}"#
        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func rejectsRelativeCwd() throws {
        let json = #"{"v":1,"kind":"cli","command":"resolve","cwd":"repo"}"#
        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    /// A directory name that legitimately ends in a space must round-trip
    /// unchanged rather than being silently trimmed to a different path. The
    /// Rust CLI already sends absolutized, non-trimmed paths, so trimming
    /// here would resolve the wrong directory without any error.
    @Test func preservesCwdWithTrailingSpaceRatherThanSilentlyTrimming() throws {
        let json = #"{"v":1,"kind":"cli","command":"resolve","cwd":"/repo dir "}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request.cwd == "/repo dir ")
    }

    @Test func responseEncodesOKAndError() throws {
        let ok = String(data: try AlasCLIResponse.ok.encode(), encoding: .utf8) ?? ""
        let error = String(data: try AlasCLIResponse.error("No file.").encode(), encoding: .utf8) ?? ""
        let workspaceError = String(data: try AlasCLIResponse.errorWithExitCode("workspace_recovery_required: recover", 3).encode(), encoding: .utf8) ?? ""

        #expect(ok.contains(#""ok":true"#) || ok.contains(#""ok": true"#))
        #expect(error.contains(#""ok":false"#) || error.contains(#""ok": false"#))
        #expect(error.contains("No file."))
        #expect(error.contains("exit_code") == false)
        #expect(workspaceError.contains(#""exit_code":3"#) || workspaceError.contains(#""exit_code": 3"#))
    }

    @Test func encodesTextResponse() throws {
        let encoded = String(data: try AlasCLIResponse.text(["a", "b"]).encode(), encoding: .utf8) ?? ""
        #expect(encoded.contains(#""ok":true"#))
        #expect(encoded.contains(#""lines":["a","b"]"#))
    }

    @Test func decodesReviewCommentsWithAndWithoutParams() throws {
        let bare = #"{"v":1,"kind":"cli","command":"review_comments","session_id":"s1"}"#
        let bareRequest = try AlasCLIRequest.decode(from: Data(bare.utf8))
        #expect(bareRequest.command == .review(.comments(sessionID: nil, state: .active)))

        let full = #"{"v":1,"kind":"cli","command":"review_comments","session_id":"s1","params":{"session_id":"rsid","state":"all"}}"#
        let fullRequest = try AlasCLIRequest.decode(from: Data(full.utf8))
        #expect(fullRequest.command == .review(.comments(sessionID: "rsid", state: .all)))
    }

    @Test func rejectsUnknownReviewCommentsState() throws {
        let json = #"{"v":1,"kind":"cli","command":"review_comments","session_id":"s1","params":{"state":"bogus"}}"#
        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func decodesReviewReplyAndResolve() throws {
        let reply = #"{"v":1,"kind":"cli","command":"review_reply","session_id":"s1","params":{"comment_id":"c1","body":"done"}}"#
        #expect(try AlasCLIRequest.decode(from: Data(reply.utf8)).command == .review(.reply(commentID: "c1", body: "done")))

        let resolve = #"{"v":1,"kind":"cli","command":"review_resolve","session_id":"s1","params":{"comment_id":"c1"}}"#
        #expect(try AlasCLIRequest.decode(from: Data(resolve.utf8)).command == .review(.resolve(commentID: "c1", reply: nil, reopen: false)))

        let reopen = #"{"v":1,"kind":"cli","command":"review_resolve","session_id":"s1","params":{"comment_id":"c1","reply":"oops","reopen":true}}"#
        #expect(try AlasCLIRequest.decode(from: Data(reopen.utf8)).command == .review(.resolve(commentID: "c1", reply: "oops", reopen: true)))
    }

    @Test func reviewReplyRequiresParams() throws {
        let json = #"{"v":1,"kind":"cli","command":"review_reply","session_id":"s1"}"#
        #expect(throws: AlasCLIRequestError.self) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    @Test func decodesReviewCommentAdd() throws {
        let json = #"{"v":1,"kind":"cli","command":"review_comment_add","session_id":"s1","params":{"path":"a.swift","start_line":3,"end_line":5,"side":"new","body":"tighten"}}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request.command == .review(.commentAdd(
            path: "a.swift", startLine: 3, endLine: 5, side: "new", body: "tighten", sessionID: nil
        )))
    }

    @Test func rejectsInvalidReviewCommentAdd() throws {
        for bad in [
            #"{"v":1,"kind":"cli","command":"review_comment_add","session_id":"s1","params":{"path":"a.swift","start_line":0,"body":"x"}}"#,
            #"{"v":1,"kind":"cli","command":"review_comment_add","session_id":"s1","params":{"path":"a.swift","start_line":5,"end_line":3,"body":"x"}}"#,
            #"{"v":1,"kind":"cli","command":"review_comment_add","session_id":"s1","params":{"path":"a.swift","start_line":3,"side":"sideways","body":"x"}}"#,
            #"{"v":1,"kind":"cli","command":"review_comment_add","session_id":"s1"}"#,
        ] {
            #expect(throws: AlasCLIRequestError.self, "should reject: \(bad)") {
                try AlasCLIRequest.decode(from: Data(bad.utf8))
            }
        }
    }

    @Test func decodesReviewFinishWithDefaultsAndVerdict() throws {
        let bare = #"{"v":1,"kind":"cli","command":"review_finish","session_id":"s1"}"#
        #expect(try AlasCLIRequest.decode(from: Data(bare.utf8)).command == .review(.finish(
            sessionID: nil, verdict: .comment, summary: ""
        )))

        let full = #"{"v":1,"kind":"cli","command":"review_finish","session_id":"s1","params":{"session_id":"rs1","verdict":"request_changes","summary":"Fix the race."}}"#
        #expect(try AlasCLIRequest.decode(from: Data(full.utf8)).command == .review(.finish(
            sessionID: "rs1", verdict: .requestChanges, summary: "Fix the race."
        )))
    }

    @Test func rejectsUnknownReviewFinishVerdict() throws {
        let json = #"{"v":1,"kind":"cli","command":"review_finish","session_id":"s1","params":{"verdict":"reject"}}"#
        #expect(throws: AlasCLIRequestError.malformed) {
            try AlasCLIRequest.decode(from: Data(json.utf8))
        }
    }

    private struct ProbeParams: Decodable, Equatable {
        var name: String
        var count: Int?
    }

    @Test func decodesTypedParamsEnvelope() throws {
        let json = #"{"v":1,"kind":"cli","command":"x","session_id":"s1","params":{"name":"a","count":2}}"#
        let params = try AlasCLIRequest.decodeParams(ProbeParams.self, from: Data(json.utf8))
        #expect(params == ProbeParams(name: "a", count: 2))
    }

    @Test func missingParamsIsNilForOptionalDecodeAndThrowsForRequired() throws {
        let json = #"{"v":1,"kind":"cli","command":"x","session_id":"s1"}"#
        #expect(try AlasCLIRequest.decodeParamsIfPresent(ProbeParams.self, from: Data(json.utf8)) == nil)
        #expect(throws: AlasCLIRequestError.malformed) {
            try AlasCLIRequest.decodeParams(ProbeParams.self, from: Data(json.utf8))
        }
    }

    @Test func mistypedParamsThrowsMalformed() throws {
        let json = #"{"v":1,"kind":"cli","command":"x","session_id":"s1","params":{"name":5}}"#
        #expect(throws: AlasCLIRequestError.malformed) {
            try AlasCLIRequest.decodeParamsIfPresent(ProbeParams.self, from: Data(json.utf8))
        }
    }
}
