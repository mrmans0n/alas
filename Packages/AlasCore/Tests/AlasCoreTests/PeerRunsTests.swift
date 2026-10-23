import Foundation
import Testing
import AlasCore
import AlasHostCore

@MainActor // `PeerRuns.perform` is main-actor API.
struct PeerRunsTests {
    func record(_ key: String, worktreeID: String = "w", status: RunStatus, id: String = UUID().uuidString) -> RunRecord {
        let fileName = String(key.split(separator: ":", maxSplits: 1)[1])
        return RunRecord(
            id: id, scriptKey: key, scriptName: (fileName as NSString).deletingPathExtension, worktreeID: worktreeID,
            branch: "feature", target: RunExecutionTarget(host: nil, workingDirectory: "/srv/feature"),
            status: status, startedAt: .distantPast
        )
    }

    func script(_ scope: RunScriptScope, _ fileName: String) -> HostRunScript {
        HostRunScript(
            scope: scope, fileName: fileName, name: (fileName as NSString).deletingPathExtension, cwd: nil,
            target: RunExecutionTarget(host: nil, workingDirectory: "/srv/feature")
        )
    }

    @Test func rowsListTheHostsScriptsThenActiveRunsItDoesNotList() {
        let build = record("repo:build.sh", status: .finished(.succeeded))
        let deploy = record("repo:deploy.sh", status: .running)
        let runs = [build, deploy, record("repo:gone.sh", status: .finished(.succeeded)),
                    record("repo:build.sh", worktreeID: "other", status: .running)]
        let rows = PeerRuns.rows(scripts: [script(.repo, "build.sh"), script(.global, "lint.sh")], runs: runs, worktreeID: "w")
        #expect(rows.map(\.script.key) == ["repo:build.sh", "global:lint.sh", "repo:deploy.sh"])
        #expect(rows.map(\.record) == [build, nil, deploy])
        #expect(rows[2].script == HostRunScript(scope: .repo, fileName: "deploy.sh", name: "deploy", cwd: nil, target: deploy.target))
        #expect(PeerRuns.rows(scripts: nil, runs: runs, worktreeID: "w").map(\.script.key) == ["repo:deploy.sh"])
    }

    @Test(arguments: [
        (PeerRuns.Command.start, RunStatus?.none, "start"),
        (.start, .finished(.failed(exitCode: 1)), "restart"),
        (.restart, .running, "restart"),
        (.stop, .running, "stop"),
        (.output(runID: "r1"), .finished(.succeeded), "output"),
    ])
    func commandsMapToTheirRequests(command: PeerRuns.Command, status: RunStatus?, expected: String) async {
        let ref = WorktreeRef(projectID: "p", path: "/srv/feature")
        let row = PeerRuns.Row(script: script(.repo, "dev.sh"), record: status.map { record("repo:dev.sh", status: $0, id: "r1") })
        var sent: [HostRequest] = []
        _ = await PeerRuns.perform(command, on: row, in: ref) { request in
            sent.append(request)
            return .done
        }
        let requests: [String: HostRequest] = [
            "start": .startRun(scriptKey: "repo:dev.sh", worktree: ref), "restart": .restartRun(scriptKey: "repo:dev.sh", worktree: ref),
            "stop": .stopRun(scriptKey: "repo:dev.sh", worktree: ref), "output": .runOutput(runID: "r1", projectID: "p"),
        ]
        #expect(sent == [requests[expected]!])
    }

    @Test(arguments: [
        (HostResponse.runStart(start: .started(runID: "r")), PeerRuns.Reply.done),
        (.runStart(start: .refused(title: "Run Script Failed", message: "Busy")), .refused(title: "Run Script Failed", message: "Busy")),
        (.runStart(start: .projectUnavailable), .refused(title: "Run Script Failed", message: "The project is no longer available on the host.")),
        (.failure(error: .notFound(what: "script repo:dev.sh")), .refused(title: "Run Script Failed", message: "The host has no script repo:dev.sh.")),
        (.failure(error: .operationInProgress), .refused(title: "Run Script Failed", message: PeerWorktreeRemoval.message(for: .operationInProgress))),
        (.runOutput(output: .text("", truncated: false)), .output(.document(text: "No output was produced.", isTruncated: false))),
        (.runOutput(output: .unavailable), .output(.unavailable)),
        (.runOutput(output: .notFinished), .refused(title: "Run Output", message: "This run has not finished yet.")),
        (.runOutput(output: .unknownRun), .refused(title: "Run Output", message: "The host no longer has this run's output.")),
    ])
    func repliesBecomeDoneARefusalOrOutput(response: HostResponse, expected: PeerRuns.Reply) async {
        let command: PeerRuns.Command = if case .runOutput = response { .output(runID: "r1") } else { .start }
        let row = PeerRuns.Row(script: script(.repo, "dev.sh"), record: record("repo:dev.sh", status: .finished(.succeeded), id: "r1"))
        #expect(await PeerRuns.perform(command, on: row, in: WorktreeRef(projectID: "p", path: "/srv/feature")) { _ in response } == expected)
    }
}
