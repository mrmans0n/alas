import Foundation
import Testing
@testable import Alas

// File scope so `@Test(arguments:)` can read them outside the main actor.
private let activateOK = #"{"jsonrpc":"2.0","id":0,"result":{}}"#
private let switchToWT = #"{"jsonrpc":"2.0","id":1,"method":"worktree/switch","params":{"id":"wt"}}"#
private let buttonTree = #"{"id":"root","kind":"vstack","children":[{"id":"go","kind":"button","label":"Go"}]}"#

private func render(tab: Int = 0, _ root: String = buttonTree) -> String {
    #"{"jsonrpc":"2.0","method":"view/render","params":{"tab":\#(tab),"root":\#(root)}}"#
}

private func taskStart(id: Int = 1, title: String = "Fix it", prompt: String = "Please fix it") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"task/start","params":{"title":"\#(title)","prompt":"\#(prompt)"}}"#
}

/// `PluginHost` is main-actor isolated because it applies actions to AppState.
@MainActor
struct PluginHostTests {
    static let limits = PluginLimits(
        fuelPerCall: 1_000_000, maxMemoryBytes: 1 << 20, maxMessageBytes: 4096, maxSendsPerCall: 8)

    final class Recorder {
        var switched: [String] = []
        var focused: [String] = []
        var tasks: [PluginTaskRequest] = []
        var completions: [@MainActor (String?) -> Void] = []
        /// How many upcoming starts are rejected before any is accepted.
        var rejections = 0
    }

    static let v1Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":1,"entry":"p.wasm"}"#
    static let v2Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":2,"entry":"p.wasm","contributes":{"tabs":[{"id":"t","title":"T"}]}}"#
    static let v3Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":3,"entry":"p.wasm","capabilities":["tasks.start"],"contributes":{"tabs":[{"id":"v","title":"V","kind":"view"},{"id":"c","title":"C"}]}}"#

    func makeHost(
        _ script: [[PluginFixtureStep]],
        grants: Set<PluginCapability> = [],
        recorder: Recorder = Recorder(),
        limits: PluginLimits = PluginHostTests.limits,
        manifest: String = PluginHostTests.v1Manifest,
        storage: PluginStorage? = nil
    ) throws -> PluginHost {
        // Nothing is written unless a test stores something, and those tests pass their own storage.
        let storage = storage ?? PluginStorage(
            file: FileManager.default.temporaryDirectory.appending(path: "plugin-storage-\(UUID().uuidString).json"))
        return PluginHost(
            manifest: try PluginManifest.parse(Data(manifest.utf8)),
            wasm: try PluginWATFixture.wasm(script),
            project: PluginProjectRef(id: "proj", name: "Project"),
            grants: grants,
            actions: PluginHostActions(
                snapshot: { PluginWorkspaceSnapshot(worktrees: []) },
                switchWorktree: { id in
                    recorder.switched.append(id)
                    return id == "wt"
                },
                focusSession: { id in
                    recorder.focused.append(id)
                    return id == "s1"
                },
                lastMessage: { id in
                    switch id {
                    case "s1": .text("x")
                    case "quiet": .none
                    default: .unknownSession
                    }
                },
                agents: { [PluginAgent(id: "claude", name: "Claude Code")] },
                startTask: { request, completion in
                    if recorder.rejections > 0 {
                        recorder.rejections -= 1
                        return .rejected(code: -32003, message: "no")
                    }
                    recorder.tasks.append(request)
                    recorder.completions.append(completion)
                    return .started(sessionId: "s\(recorder.tasks.count)", branch: "task/x")
                }),
            storage: storage,
            limits: limits)
    }

    func ticks(_ host: PluginHost) -> [String] {
        host.trace.filter { $0.direction == .toPlugin && $0.text.contains(#""method":"tick""#) }.map(\.text)
    }

    func lastReply(_ host: PluginHost) -> String? {
        host.trace.last { $0.direction == .toPlugin }?.text
    }

    private static let regionsR = #"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0,"regions":[{"id":"r","label":"R","rect":[0,0,4,4]}]}}"#

    /// Hiding the tab resets the clock, so the next tick does not carry the hidden time.
    @Test func ticksNeedAVisibleTabAndResumeWithZeroDelta() async throws {
        let host = try makeHost([[.send(activateOK)]], manifest: Self.v2Manifest)
        await host.activate()
        let start = ContinuousClock.now
        await host.tick(at: start)
        #expect(ticks(host).isEmpty)
        host.setViewVisible(true)
        await host.tick(at: start)
        await host.tick(at: start + .milliseconds(66))
        host.setViewVisible(false)
        await host.tick(at: start + .seconds(1))
        host.setViewVisible(true)
        await host.tick(at: start + .seconds(600))
        #expect(ticks(host).map { $0.contains(#""dt":0"#) } == [true, false, true])
        #expect(ticks(host)[1].contains(#""dt":66"#))
    }

    @Test func aTickIsDroppedWhileADeliveryIsInFlight() async throws {
        let host = try makeHost([[.send(activateOK)]], manifest: Self.v2Manifest)
        await host.activate()
        host.setViewVisible(true)
        let first = Task { await host.tick(at: .now) }
        // The tick is traced just before the host suspends inside the plugin call.
        var spins = 0
        while ticks(host).isEmpty, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        try #require(!ticks(host).isEmpty)
        await host.tick(at: .now)
        await first.value
        #expect(ticks(host).count == 1)
    }

    @Test func presentedFramesAndRegionsAreKeptUntilTheHostFails() async throws {
        let host = try makeHost(
            [[.send(activateOK), .send(Self.regionsR), .present(tab: 0, ptr: 0, len: 16, width: 2)], [.trap]],
            manifest: Self.v2Manifest)
        await host.activate()
        #expect(host.frames[0]?.height == 2)
        #expect(host.regions[0]?.map(\.id) == ["r"])
        host.setViewVisible(true)
        await host.tick(at: .now)
        #expect(host.frames.isEmpty)
        #expect(host.regions.isEmpty)
    }

    @Test func aClickOnAKnownRegionReachesThePlugin() async throws {
        let host = try makeHost([[.send(activateOK), .send(Self.regionsR)]], manifest: Self.v2Manifest)
        await host.activate()
        await host.click(tab: 0, region: "nope")
        await host.click(tab: 0, region: "r")
        let clicks = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("canvas/click") }
        #expect(clicks.count == 1)
        #expect(clicks.first?.text.contains(#""region":"r""#) == true)
    }

    @Test(arguments: [
        #"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":3,"regions":[]}}"#,
        #"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0,"regions":[{"id":"r","label":"R","rect":[0,0,4]}]}}"#,
        #"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0}}"#,
    ])
    func malformedRegionsStopThePlugin(message: String) async throws {
        let host = try makeHost([[.send(activateOK), .send(message)]], manifest: Self.v2Manifest)
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains("canvas/regions"))
    }

    @Test func oversizedRegionTextIsTruncatedNotFatal() async throws {
        let id = String(repeating: "i", count: 100)
        let label = String(repeating: "l", count: 300)
        var limits = Self.limits
        limits.maxMessageBytes = 1 << 14
        let host = try makeHost([[
            .send(activateOK),
            .send(#"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0,"regions":[{"id":"\#(id)","label":"\#(label)","rect":[0,0,1,1]}]}}"#),
        ]], limits: limits, manifest: Self.v2Manifest)
        await host.activate()
        #expect(host.state == .active)
        #expect(host.regions[0]?.first?.id.utf8.count == PluginHost.regionIDByteLimit)
        #expect(host.regions[0]?.first?.label.unicodeScalars.count == PluginHost.regionLabelLimit)
    }

    struct FocusCase: Sendable {
        let grants: Set<PluginCapability>
        let id: String
        let reply: String
        let focused: [String]
    }

    /// A session that ended answers -32003 and the plugin keeps running.
    @Test(arguments: [
        FocusCase(grants: [], id: "s1", reply: #""code":-32001"#, focused: []),
        FocusCase(grants: [.sessionFocus], id: "s1", reply: #""result":{}"#, focused: ["s1"]),
        FocusCase(grants: [.sessionFocus], id: "gone", reply: #""code":-32003"#, focused: ["gone"]),
    ])
    func sessionFocusIsCheckedAgainstGrants(_ testCase: FocusCase) async throws {
        let recorder = Recorder()
        let request = #"{"jsonrpc":"2.0","id":1,"method":"session/focus","params":{"id":"\#(testCase.id)"}}"#
        let host = try makeHost(
            [[.send(activateOK), .send(request)]], grants: testCase.grants, recorder: recorder)
        await host.activate()
        #expect(host.state == .active)
        #expect(recorder.focused == testCase.focused)
        #expect(lastReply(host)?.contains(testCase.reply) == true)
    }

    struct ReadCase: Sendable {
        let method: String
        let params: String
        let grants: Set<PluginCapability>
        let reply: String
        var api = 3
    }

    @Test(arguments: [
        ReadCase(method: "session/last_message", params: #"{"id":"s1"}"#, grants: [.workspaceRead], reply: #""code":-32601"#, api: 2),
        ReadCase(method: "agent/list", params: "{}", grants: [.workspaceRead], reply: #""code":-32601"#, api: 2),
        ReadCase(method: "session/last_message", params: #"{"id":"s1"}"#, grants: [], reply: #""code":-32001"#),
        ReadCase(method: "session/last_message", params: #"{"id":"s1"}"#, grants: [.workspaceRead], reply: #""message":"x""#),
        ReadCase(method: "session/last_message", params: #"{"id":"quiet"}"#, grants: [.workspaceRead], reply: #""result":{"message":null}"#),
        ReadCase(method: "session/last_message", params: #"{"id":"gone"}"#, grants: [.workspaceRead], reply: #""code":-32003"#),
        ReadCase(method: "agent/list", params: "{}", grants: [.workspaceRead], reply: #""name":"Claude Code""#),
    ])
    func workspaceReadRequestsAreGatedAndShaped(_ c: ReadCase) async throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"\#(c.method)","params":\#(c.params)}"#
        let host = try makeHost([[.send(activateOK), .send(request)]], grants: c.grants, manifest: c.api == 3 ? Self.v3Manifest : Self.v2Manifest)
        await host.activate()
        #expect(host.state == .active)
        #expect(lastReply(host)?.contains(c.reply) == true)
    }

    @Test
    func lastMessageIsBoundedWithoutSplittingACharacter() {
        let text = String(repeating: "é", count: 3000)
        let bounded = PluginLastMessageText.bounded(text)
        #expect(bounded.utf8.count <= 4096)
        #expect(text.hasPrefix(bounded))
        #expect(bounded.count == 2048)
    }

    @Test(arguments: [1, 2])
    func activationHandshakeMakesTheHostActive(api: Int) async throws {
        let host = try makeHost([[.send(activateOK)]], manifest: api == 1 ? Self.v1Manifest : Self.v2Manifest)
        await host.activate()
        #expect(host.state == .active)
        #expect(lastReply(host)?.contains(#""api":\#(api)"#) == true)
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
            grants: [], expectedReply: #""code":-32601"#, expectedSwitches: []),
        // Storage is API 3 only; the host under test runs an API 1 manifest.
        RequestCase(
            request: #"{"jsonrpc":"2.0","id":1,"method":"storage/get","params":{"key":"k"}}"#,
            grants: [], expectedReply: #""code":-32601"#, expectedSwitches: []),
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

    // MARK: - API 3

    func replies(_ host: PluginHost) -> [String] {
        host.trace.filter { $0.direction == .toPlugin && $0.text.contains(#""id":"#) }.map(\.text)
    }

    @Test func aValidRenderReplacesTheTabsTree() async throws {
        let host = try makeHost(
            [[.send(activateOK), .send(render(#"{"id":"root","kind":"vstack","children":[]}"#)), .send(render())]],
            manifest: Self.v3Manifest)
        await host.activate()
        #expect(host.state == .active)
        #expect(host.views[0]?.children.count == 1)
    }

    @Test(arguments: [
        ([PluginFixtureStep.send(render(#"{"id":"a","kind":"vstack","children":[{"id":"a","kind":"divider"}]}"#))], "view/render"),
        ([.send(render(#"{"id":"a","kind":"nope"}"#))], "view/render"),
        ([.send(render(tab: 1))], "view/render"),
        ([.send(render(tab: 9))], "view/render"),
        ([.send(#"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0,"regions":[]}}"#)], "canvas/regions"),
        ([.present(tab: 0, ptr: 0, len: 16, width: 2)], "view tab"),
    ])
    func malformedOrMisdirectedViewMessagesStopThePlugin(steps: [PluginFixtureStep], fragment: String) async throws {
        let host = try makeHost([[.send(activateOK)] + steps], manifest: Self.v3Manifest)
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains(fragment))
    }

    @Test func viewEventsOnlyReachNodesInTheCurrentTree() async throws {
        let host = try makeHost([[.send(activateOK), .send(render())]], manifest: Self.v3Manifest)
        await host.activate()
        await host.viewEvent(tab: 0, id: "nope", kind: "click", value: nil)
        await host.viewEvent(tab: 0, id: "go", kind: "click", value: nil)
        let events = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("view/event") }
        #expect(events.count == 1)
        #expect(events.first?.text.contains(#""id":"go""#) == true)
    }

    @Test func taskStartNeedsTheGrant() async throws {
        let recorder = Recorder()
        let host = try makeHost([[.send(activateOK), .send(taskStart())]], recorder: recorder, manifest: Self.v3Manifest)
        await host.activate()
        #expect(lastReply(host)?.contains(#""code":-32001"#) == true)
        #expect(recorder.tasks.isEmpty)
    }

    /// The gate reopens on success and on failure, and a stale completion is ignored.
    @Test func taskStartAllowsOneInFlightAndReopens() async throws {
        let recorder = Recorder()
        let host = try makeHost(
            [[.send(activateOK), .send(taskStart(id: 1)), .send(taskStart(id: 2))], [], [], [.send(taskStart(id: 3))]],
            grants: [.tasksStart, .workspaceRead], recorder: recorder, manifest: Self.v3Manifest)
        await host.activate()
        let first = replies(host)
        try #require(first.count == 3)
        #expect(first[1].contains(#""sessionId":"s1""#))
        #expect(first[2].contains(#""code":-32003"#))

        recorder.completions[0](nil)
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        #expect(lastReply(host)?.contains(#""sessionId":"s2""#) == true)

        recorder.completions[0]("stale")
        recorder.completions[1]("boom")
        let delivered = await awaitCondition { host.trace.contains { $0.text.contains("task/failed") } }
        #expect(delivered)
        let failed = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("task/failed") }
        #expect(failed.count == 1)
        #expect(failed.first?.text.contains(#""reason":"boom""#) == true)
        #expect(failed.first?.text.contains(#""sessionId":"s2""#) == true)
        #expect(recorder.tasks.count == 2)
    }

    @Test func aRejectedTaskStartReopensTheGate() async throws {
        let recorder = Recorder()
        recorder.rejections = 1
        let host = try makeHost(
            [[.send(activateOK), .send(taskStart(id: 1)), .send(taskStart(id: 2))]],
            grants: [.tasksStart], recorder: recorder, manifest: Self.v3Manifest)
        await host.activate()
        let sent = replies(host)
        try #require(sent.count == 3)
        #expect(sent[1].contains(#""code":-32003"#))
        #expect(sent[2].contains(#""sessionId":"s1""#))
    }

    @Test(arguments: [
        ("", "p"),
        ("t", ""),
        ("t", String(repeating: "x", count: 32 * 1024 + 1)),
    ])
    func invalidTaskParamsAreRejected(title: String, prompt: String) async throws {
        let recorder = Recorder()
        var limits = Self.limits
        limits.maxMessageBytes = 1 << 16
        let host = try makeHost(
            [[.send(activateOK), .send(taskStart(title: title, prompt: prompt))]],
            grants: [.tasksStart], recorder: recorder, limits: limits, manifest: Self.v3Manifest)
        await host.activate()
        #expect(lastReply(host)?.contains(#""code":-32602"#) == true)
        #expect(recorder.tasks.isEmpty)
    }

    /// Storage needs no grant.
    @Test func storageRoundTripsAndEnforcesItsLimits() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "plugin-storage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let storage = PluginStorage(file: file)
        let big = Data(("\"" + String(repeating: "x", count: PluginStorage.maxTotalBytes - 100) + "\"").utf8)
        try #require(storage.set("big", value: big) == .stored)
        func request(_ id: Int, _ method: String, _ params: String) -> PluginFixtureStep {
            .send(#"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#)
        }
        let host = try makeHost([[
            .send(activateOK),
            request(1, "storage/set", #"{"key":"k","value":{"a":1}}"#),
            request(2, "storage/get", #"{"key":"k"}"#),
            request(3, "storage/keys", "{}"),
            request(4, "storage/set", #"{"key":"","value":1}"#),
            request(5, "storage/set", #"{"key":"k2","value":"\#(String(repeating: "y", count: 200))"}"#),
            request(6, "storage/get", #"{"key":"\#(String(repeating: "k", count: 129))"}"#),
        ]], manifest: Self.v3Manifest, storage: storage)
        await host.activate()
        #expect(host.state == .active)
        let sent = replies(host)
        try #require(sent.count == 7)
        #expect(sent[1].contains(#""result":{}"#))
        #expect(sent[2].contains(#""value":{"a":1}"#))
        #expect(sent[3].contains(#"["big","k"]"#))
        #expect(sent[4].contains(#""code":-32602"#))
        #expect(sent[5].contains(#""code":-32003"#) && sent[5].contains("storage full"))
        #expect(storage.get("k2") == nil)
        #expect(sent[6].contains(#""code":-32602"#) && sent[6].contains("invalid storage key"))
    }
}
