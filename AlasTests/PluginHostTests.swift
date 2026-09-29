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
        recorder: Recorder = Recorder(),
        limits: PluginLimits = PluginHostTests.limits
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
            limits: limits)
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
        ([.send(#"{"jsonrpc":"2.0","id":0}"#)], "malformed"),
        ([.send(#"{"jsonrpc":"2.0","id":0,"result":{},"error":{"code":1,"message":"x"}}"#)], "malformed"),
        ([.send(#"{"jsonrpc":"2.0","id":0,"result":{},"error":null}"#)], "malformed"),
        ([.send(#"{"jsonrpc":"2.0","method":null,"id":0,"result":{}}"#)], "malformed"),
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

    @Test func aRequestBeforeTheActivationReplyStopsThePluginWithoutBeingActedOn() async throws {
        let recorder = Recorder()
        let host = try makeHost(
            [[.send(switchToWT), .send(activateOK)]], grants: [.worktreeSwitch], recorder: recorder)
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains("before answering alas/activate"))
        #expect(recorder.switched.isEmpty)
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

    @Test func aPluginThatKeepsRequestingIsStoppedAtTheRoundTripLimit() async throws {
        let snapshotRequest = #"{"jsonrpc":"2.0","id":1,"method":"workspace/snapshot"}"#
        let chatter = Array(repeating: [PluginFixtureStep.send(snapshotRequest)], count: 8)
        var limits = Self.limits
        limits.maxRoundTripsPerDelivery = 4
        let host = try makeHost(
            [[.send(activateOK), .send(snapshotRequest)]] + chatter, grants: [.workspaceRead], limits: limits)
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains("round trips"))
    }

    @Test func deactivatingWhileTheModuleIsLoadingKeepsTheHostStopped() async throws {
        let host = try makeHost([[.send(activateOK)]])
        let activation = Task { await host.activate() }
        await Task.yield()
        await host.deactivate()
        await activation.value
        #expect(host.state == .stopped)
    }

    @Test func deactivatingDuringACallDropsWhatItSent() async throws {
        let recorder = Recorder()
        let host = try makeHost(
            [[.send(activateOK)], [.send(switchToWT)]],
            grants: [.workspaceRead, .worktreeSwitch], recorder: recorder)
        await host.activate()
        let change = Task { await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: [])) }
        // The message is traced just before the host suspends inside the plugin call.
        var spins = 0
        while !host.trace.contains(where: { $0.text.contains("workspace/changed") }), spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        try #require(host.trace.contains { $0.text.contains("workspace/changed") })
        await host.deactivate()
        await change.value
        #expect(host.state == .stopped)
        #expect(recorder.switched.isEmpty)
    }

    @Test func logsWithAnUnknownLevelAreDropped() async throws {
        let hugeLevel = String(repeating: "x", count: 3000)
        let host = try makeHost([[
            .send(activateOK),
            .send(#"{"jsonrpc":"2.0","method":"log","params":{"level":"\#(hugeLevel)","message":"a"}}"#),
            .send(#"{"jsonrpc":"2.0","method":"log","params":{"level":"warn","message":"b"}}"#),
        ]])
        await host.activate()
        #expect(host.log.map(\.level) == ["warn"])
    }

    @Test func anOversizedActivationErrorIsBoundedInTheFailureReason() async throws {
        let long = String(repeating: "x", count: 3000)
        let host = try makeHost([[.send(#"{"jsonrpc":"2.0","id":0,"error":{"code":1,"message":"\#(long)"}}"#)]])
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.hasPrefix("plugin rejected activation: "))
        #expect(reason.unicodeScalars.count <= "plugin rejected activation: ".unicodeScalars.count + PluginHost.logMessageLimit)
    }

    /// The request fits the 4,096-byte test limit (4,086 bytes) but a reply that echoed the whole
    /// method name would not (4,129 bytes), which used to stop the plugin instead of answering it.
    @Test func anErrorReplyThatEchoesAnOversizedMethodStillFits() async throws {
        let method = String(repeating: "m", count: 4050)
        let host = try makeHost([[
            .send(activateOK),
            .send(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)"}"#),
        ]])
        await host.activate()
        #expect(host.state == .active)
        // The trace keeps 2,000 bytes and key order is not fixed, so check the text at the start of the message.
        #expect(lastReply(host)?.contains("method not found") == true)
    }

    /// The id is echoed in the reply and cannot be shortened, so the limit is on the id itself.
    @Test(arguments: [(256, false), (257, true)])
    func aRequestIDLongerThanTheLimitStopsThePlugin(idBytes: Int, stops: Bool) async throws {
        let id = String(repeating: "i", count: idBytes)
        let host = try makeHost([[
            .send(activateOK),
            .send(#"{"jsonrpc":"2.0","id":"\#(id)","method":"nope/x"}"#),
        ]])
        await host.activate()
        if stops {
            guard case .failed(let reason) = host.state else {
                Issue.record("expected failed, got \(host.state)")
                return
            }
            #expect(reason.contains("request id longer than 256 bytes"))
        } else {
            #expect(host.state == .active)
            #expect(lastReply(host)?.contains("method not found") == true)
        }
    }

    @Test func aRestartedHostStartsWithAnEmptyLog() async throws {
        let host = try makeHost([[.trap]])
        await host.activate()
        #expect(host.log.count == 1)
        await host.activate()
        #expect(host.log.count == 1, "the second instance should not show the first one's failure")
    }

    /// The second case is a single grapheme cluster of 3,001 scalars, which a `Character` count would not cut.
    @Test(arguments: [
        String(repeating: "x", count: 3000),
        "e" + String(repeating: "\u{0301}", count: 3000),
    ])
    func oversizedLogMessagesAreTruncated(message: String) async throws {
        var limits = Self.limits
        limits.maxMessageBytes = 1 << 14
        let host = try makeHost([[
            .send(activateOK),
            .send(#"{"jsonrpc":"2.0","method":"log","params":{"level":"info","message":"\#(message)"}}"#),
        ]], limits: limits)
        await host.activate()
        #expect(host.log.count == 1)
        #expect(host.log.first?.message.unicodeScalars.count == PluginHost.logMessageLimit)
    }
}
