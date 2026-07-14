import Foundation
import Testing
@testable import Alas

struct AlasCLIRequestTests {
    @Test func decodeOpenRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"open","session_id":"s1","paths":["/tmp/a.txt","/tmp/b.txt"]}"#

        let request = try AlasCLIRequest.decode(from: Data(json.utf8))

        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .open(paths: ["/tmp/a.txt", "/tmp/b.txt"])))
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
        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .review(.localChanges)))
    }

    @Test func decodesProviderReviewRequest() throws {
        let json = #"{"v":1,"kind":"cli","command":"review","session_id":"s1","target":"123"}"#
        let request = try AlasCLIRequest.decode(from: Data(json.utf8))
        #expect(request == AlasCLIRequest(version: 1, sessionId: "s1", cwd: nil, command: .review(.provider(target: "123"))))
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

        #expect(ok.contains(#""ok":true"#) || ok.contains(#""ok": true"#))
        #expect(error.contains(#""ok":false"#) || error.contains(#""ok": false"#))
        #expect(error.contains("No file."))
    }

    @Test func encodesTextResponse() throws {
        let encoded = String(data: try AlasCLIResponse.text(["a", "b"]).encode(), encoding: .utf8) ?? ""
        #expect(encoded.contains(#""ok":true"#))
        #expect(encoded.contains(#""lines":["a","b"]"#))
    }
}
