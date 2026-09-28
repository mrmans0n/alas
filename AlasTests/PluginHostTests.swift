import Foundation
import Testing
@testable import Alas

// File scope so `@Test(arguments:)` can read them outside the main actor.
private let activateOK = #"{"jsonrpc":"2.0","id":0,"result":{}}"#
private let switchToWT = #"{"jsonrpc":"2.0","id":1,"method":"worktree/switch","params":{"id":"wt"}}"#

/// `PluginHost` is main-actor isolated because it applies actions to AppState.
@MainActor
struct PluginHostTests {
    static let limits = PluginLimits(
        fuelPerCall: 1_000_000, maxMemoryBytes: 1 << 20, maxMessageBytes: 4096, maxSendsPerCall: 8)

    final class Recorder {
        var switched: [String] = []
    }

    func makeHost(
        _ script: [[PluginFixtureStep]],
        grants: Set<PluginCapability> = [],
        recorder: Recorder = Recorder()
    ) throws -> PluginHost {
        let manifest = try PluginManifest.parse(Data(
            #"{"id":"io.test.plugin","name":"Test","version":"1","api":1,"entry":"p.wasm"}"#.utf8))
        return PluginHost(
            manifest: manifest,
            wasm: try PluginWATFixture.wasm(script),
            project: PluginProjectRef(id: "proj", name: "Project"),
            grants: grants,
            actions: PluginHostActions(
                snapshot: { PluginWorkspaceSnapshot(worktrees: []) },
                switchWorktree: { id in
                    recorder.switched.append(id)
                    return id == "wt"
                }),
            limits: Self.limits)
    }

    func lastReply(_ host: PluginHost) -> String? {
        host.trace.last { $0.direction == .toPlugin }?.text
    }

    @Test func activationHandshakeMakesTheHostActive() async throws {
        let host = try makeHost([[.send(activateOK)]])
        await host.activate()
        #expect(host.state == .active)
    }

    @Test(arguments: [
        ([PluginFixtureStep](), "did not respond to alas/activate"),
        ([.send(#"{"jsonrpc":"2.0","id":0,"error":{"code":1,"message":"nope"}}"#)], "rejected activation: nope"),
        ([.send("{not json")], "malformed"),
        ([.trap], "unreachable"),
    ])
    func activationFailuresStopThePlugin(steps: [PluginFixtureStep], fragment: String) async throws {
        let host = try makeHost([steps])
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains(fragment))
    }

    /// A single case for `requestsAreCheckedAgainstGrants`. Swift Testing's
    /// `@Test(arguments:)` sugar only supports a single collection of 1- or
    /// 2-tuples; four fields need a wrapper type instead.
    struct RequestCase: Sendable {
        let request: String
        let grants: Set<PluginCapability>
        let expectedReply: String
        let expectedSwitches: [String]
    }

    @Test(arguments: [
        RequestCase(request: switchToWT, grants: [], expectedReply: #""code":-32001"#, expectedSwitches: []),
        RequestCase(request: switchToWT, grants: [.worktreeSwitch], expectedReply: #""result":{}"#, expectedSwitches: ["wt"]),
        RequestCase(
            request: #"{"jsonrpc":"2.0","id":1,"method":"worktree/switch","params":{"id":"gone"}}"#,
            grants: [.worktreeSwitch], expectedReply: #""code":-32003"#, expectedSwitches: ["gone"]),
        RequestCase(
            request: #"{"jsonrpc":"2.0","id":1,"method":"worktree/switch","params":{}}"#,
            grants: [.worktreeSwitch], expectedReply: #""code":-32602"#, expectedSwitches: []),
        RequestCase(
            request: #"{"jsonrpc":"2.0","id":1,"method":"nope/x"}"#,
            grants: [.worktreeSwitch], expectedReply: #""code":-32601"#, expectedSwitches: []),
    ])
    func requestsAreCheckedAgainstGrants(_ testCase: RequestCase) async throws {
        let recorder = Recorder()
        let host = try makeHost(
            [[.send(activateOK), .send(testCase.request)]], grants: testCase.grants, recorder: recorder)
        await host.activate()
        #expect(host.state == .active)
        #expect(recorder.switched == testCase.expectedSwitches)
        #expect(lastReply(host)?.contains(testCase.expectedReply) == true)
    }

    @Test(arguments: [(Set<PluginCapability>(), 0), (Set<PluginCapability>([.workspaceRead]), 1)])
    func workspaceChangesNeedTheReadGrant(grants: Set<PluginCapability>, deliveries: Int) async throws {
        let host = try makeHost([[.send(activateOK)]], grants: grants)
        await host.activate()
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        let changed = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("workspace/changed") }
        #expect(changed.count == deliveries)
    }

    @Test func strayResponsesAreIgnored() async throws {
        let host = try makeHost([[
            .send(activateOK),
            .send(activateOK),
            .send(#"{"jsonrpc":"2.0","id":99,"result":{}}"#),
        ]])
        await host.activate()
        #expect(host.state == .active)
    }

    @Test func deactivationIgnoresWhatThePluginSendsBack() async throws {
        let recorder = Recorder()
        let host = try makeHost(
            [[.send(activateOK)], [.send(switchToWT)]], grants: [.worktreeSwitch], recorder: recorder)
        await host.activate()
        await host.deactivate()
        #expect(host.state == .stopped)
        #expect(recorder.switched.isEmpty)
    }
}
