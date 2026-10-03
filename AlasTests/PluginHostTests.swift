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

private func render(panel: String, _ root: String = buttonTree) -> String {
    #"{"jsonrpc":"2.0","method":"view/render","params":{"panel":"\#(panel)","root":\#(root)}}"#
}

private func taskStart(id: Int = 1, title: String = "Fix it", prompt: String = "Please fix it") -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"task/start","params":{"title":"\#(title)","prompt":"\#(prompt)"}}"#
}

private func request(_ id: Int, _ method: String, _ params: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
}

private func fetch(_ id: Int = 1, url: String = "https://api.example.com/x", auth: String? = nil) -> String {
    let headers = auth.map { #","headers":{"Authorization":"\#($0)"}"# } ?? ""
    return request(id, "http/fetch", #"{"method":"GET","url":"\#(url)"\#(headers)}"#)
}

private func processCall(_ id: Int, _ method: String = "process/run", _ process: String = "install", worktree: String = "wt", args: [String]? = nil) -> String {
    let args = args.map { ",\"args\":[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? ""
    return request(id, method, #"{"id":"\#(process)","worktree":"\#(worktree)"\#(args)}"#)
}

private let api6Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":6,"entry":"p.js","contributes":{"commands":[{"id":"fix","title":"Fix","slots":["changes.toolbar"]}],"panels":[{"id":"checks","title":"Checks","location":"changes.section"},{"id":"explain","title":"Explain","location":"run.report.section"}]}}"#
private let api5Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":5,"entry":"p.js"}"#

/// A response to the request Alas sent with `id` (API 7).
private func answer(_ id: Int, _ body: String) -> PluginFixtureStep {
    .send(#"{"jsonrpc":"2.0","id":\#(id),\#(body)}"#)
}

private func decorate(_ slot: String, target: String, worktree: String? = nil, _ items: String) -> PluginFixtureStep {
    let worktree = worktree.map { #","worktree":"\#($0)""# } ?? ""
    return .send(#"{"jsonrpc":"2.0","method":"decorations/set","params":{"slot":"\#(slot)","target":"\#(target)"\#(worktree),"items":[\#(items)]}}"#)
}

/// `PluginHost` is main-actor isolated because it applies actions to AppState.
@MainActor
struct PluginHostTests {
    static let limits = PluginLimits(timePerCall: .milliseconds(500), maxMessageBytes: 4096, maxSendsPerCall: 8)

    final class Recorder {
        var switched: [String] = []
        var focused: [String] = []
        var tasks: [PluginTaskRequest] = []
        var completions: [@MainActor (String?) -> Void] = []
        /// How many upcoming starts are rejected before any is accepted.
        var rejections = 0
        var notes: [String] = []
        var sent: [String] = []
        var runsStarted: [String] = []
        var comments: [String] = []
        /// A run of "repo:slow.sh" waits here, then records whether it was cancelled.
        var slowRun: CheckedContinuation<Void, Never>?
        var slowRunCancelled: Bool?
    }

    static let plainManifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":4,"entry":"p.js"}"#
    static let canvasManifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":4,"entry":"p.js","contributes":{"tabs":[{"id":"t","title":"T"}]}}"#
    static let viewManifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":5,"entry":"p.js","capabilities":["tasks.start"],"contributes":{"tabs":[{"id":"v","title":"V","kind":"view"},{"id":"c","title":"C"}],"panels":[{"id":"p","title":"P"}]}}"#

    func makeHost(
        _ script: [[PluginFixtureStep]],
        grants: Set<PluginCapability> = [],
        recorder: Recorder = Recorder(),
        limits: PluginLimits = PluginHostTests.limits,
        manifest: String = PluginHostTests.plainManifest,
        storage: PluginStorage? = nil,
        pluginStorage: PluginStorage? = nil,
        settings: PluginSettings? = nil,
        transport: FakeTransport = FakeTransport(),
        sleeper: Sleeper = Sleeper(),
        launcher: FakeLauncher = FakeLauncher(),
        worktreeRoot: URL? = nil,
        now: @escaping () -> ContinuousClock.Instant = { .now }
    ) throws -> PluginHost {
        // Nothing is written unless a test stores something, and those tests pass their own storage.
        let storage = storage ?? PluginStorage(
            file: FileManager.default.temporaryDirectory.appending(path: "plugin-storage-\(UUID().uuidString).json"))
        let manifest = try PluginManifest.parse(Data(manifest.utf8))
        return PluginHost(
            manifest: manifest,
            source: PluginJSFixture.source(script),
            project: PluginProjectRef(id: "proj", name: "Project"),
            grants: grants,
            actions: PluginHostActions(
                snapshot: {
                    PluginWorkspaceSnapshot(worktrees: [.init(id: "wt", branch: "main", current: true, dirty: nil, sessions: [])])
                },
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
                },
                notify: { title, body in recorder.notes.append("\(title)|\(body)") },
                sendToSession: { session, text in
                    recorder.sent.append("\(session)|\(text)")
                    return session == "s1" ? nil : "the session did not accept the prompt"
                },
                startRun: { worktree, script in
                    recorder.runsStarted.append("\(worktree)|\(script)")
                    if script == "repo:slow.sh" {
                        await withCheckedContinuation { recorder.slowRun = $0 }
                        recorder.slowRunCancelled = Task.isCancelled
                        return nil
                    }
                    return script == "repo:dev.sh" ? nil : "unknown run script \(script)"
                },
                runOutput: { run in run == "live" ? .notFinished : .unknownRun },
                addReviewComment: { comment, author in
                    recorder.comments.append("\(author)|\(comment.worktree)|\(comment.path)|\(comment.line)")
                    return nil
                },
                worktreePath: { $0 == "wt" ? worktreeRoot ?? URL(fileURLWithPath: "/tmp/wt") : nil }),
            storage: storage,
            pluginStorage: pluginStorage ?? PluginStorage(
                file: FileManager.default.temporaryDirectory.appending(path: "plugin-storage-\(UUID().uuidString)")),
            settings: settings ?? Self.settings(manifest),
            transport: transport,
            launcher: launcher,
            limits: limits,
            now: now,
            sleep: { try await sleeper.sleep($0) })
    }

    static func settings(_ manifest: PluginManifest) -> PluginSettings {
        PluginSettings(
            pluginID: manifest.id, declared: manifest.settings,
            storage: PluginStorage(file: FileManager.default.temporaryDirectory.appending(path: "plugin-settings-\(UUID().uuidString)")),
            secrets: RemoteInMemorySecretStore())
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
        let host = try makeHost([[.send(activateOK)]], manifest: Self.canvasManifest)
        await host.activate()
        let start = ContinuousClock.now
        await host.tick(at: start)
        #expect(ticks(host).isEmpty)
        host.setTabVisible(0, true)
        await host.tick(at: start)
        await host.tick(at: start + .milliseconds(66))
        host.setTabVisible(0, false)
        await host.tick(at: start + .seconds(1))
        host.setTabVisible(0, true)
        await host.tick(at: start + .seconds(600))
        #expect(ticks(host).map { $0.contains(#""dt":0"#) } == [true, false, true])
        #expect(ticks(host)[1].contains(#""dt":66"#))
    }

    @Test func aTickIsDroppedWhileADeliveryIsInFlight() async throws {
        let host = try makeHost([[.send(activateOK)]], manifest: Self.canvasManifest)
        await host.activate()
        host.setTabVisible(0, true)
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
            [[.send(activateOK), .send(Self.regionsR), .present(tab: 0, length: 16, width: 2)], [.throw]],
            manifest: Self.canvasManifest)
        await host.activate()
        #expect(host.frames[0]?.height == 2)
        #expect(host.regions[0]?.map(\.id) == ["r"])
        host.setTabVisible(0, true)
        await host.tick(at: .now)
        #expect(host.frames.isEmpty)
        #expect(host.regions.isEmpty)
    }

    @Test func aClickOnAKnownRegionReachesThePlugin() async throws {
        let host = try makeHost([[.send(activateOK), .send(Self.regionsR)]], manifest: Self.canvasManifest)
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
        let host = try makeHost([[.send(activateOK), .send(message)]], manifest: Self.canvasManifest)
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
        ]], limits: limits, manifest: Self.canvasManifest)
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
    }

    @Test(arguments: [
        ReadCase(method: "session/last_message", params: #"{"id":"s1"}"#, grants: [], reply: #""code":-32001"#),
        ReadCase(method: "session/last_message", params: #"{"id":"s1"}"#, grants: [.workspaceRead], reply: #""code":-32001"#),
        ReadCase(method: "session/last_message", params: #"{"id":"s1"}"#, grants: [.sessionRead], reply: #""message":"x""#),
        ReadCase(method: "session/last_message", params: #"{"id":"quiet"}"#, grants: [.sessionRead], reply: #""result":{"message":null}"#),
        ReadCase(method: "session/last_message", params: #"{"id":"gone"}"#, grants: [.sessionRead], reply: #""code":-32003"#),
        ReadCase(method: "agent/list", params: "{}", grants: [.workspaceRead], reply: #""name":"Claude Code""#),
    ])
    func workspaceReadRequestsAreGatedAndShaped(_ c: ReadCase) async throws {
        let request = #"{"jsonrpc":"2.0","id":1,"method":"\#(c.method)","params":\#(c.params)}"#
        let host = try makeHost([[.send(activateOK), .send(request)]], grants: c.grants, manifest: Self.viewManifest)
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

    @Test func activationHandshakeMakesTheHostActive() async throws {
        let host = try makeHost([[.send(activateOK)]])
        await host.activate()
        #expect(host.state == .active)
        #expect(lastReply(host)?.contains(#""api":4"#) == true)
    }

    @Test(arguments: [
        ([PluginFixtureStep](), "did not respond to alas/activate"),
        ([.send(#"{"jsonrpc":"2.0","id":0,"error":{"code":1,"message":"nope"}}"#)], "rejected activation: nope"),
        ([.send("{not json")], "malformed"),
        ([.send(#"{"jsonrpc":"2.0","id":0}"#)], "malformed"),
        ([.send(#"{"jsonrpc":"2.0","id":0,"result":{},"error":{"code":1,"message":"x"}}"#)], "malformed"),
        ([.send(#"{"jsonrpc":"2.0","id":0,"result":{},"error":null}"#)], "malformed"),
        ([.send(#"{"jsonrpc":"2.0","method":null,"id":0,"result":{}}"#)], "malformed"),
        ([.throw], "boom"),
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
        let host = try makeHost([[.throw]])
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

    @Test func aValidRenderReplacesTheTabsOrPanelsTree() async throws {
        let host = try makeHost(
            [[.send(activateOK), .send(render(#"{"id":"root","kind":"vstack","children":[]}"#)), .send(render()),
              .send(render(panel: "p", #"{"id":"side","kind":"vstack","children":[]}"#))]],
            manifest: Self.viewManifest)
        await host.activate()
        #expect(host.state == .active)
        #expect(host.views[0]?.children.count == 1)
        #expect(host.panelViews["p"]?.id == "side")
        #expect(host.views.count == 1)
    }

    @Test(arguments: [
        ([PluginFixtureStep.send(render(#"{"id":"a","kind":"vstack","children":[{"id":"a","kind":"divider"}]}"#))], "view/render"),
        ([.send(render(#"{"id":"a","kind":"nope"}"#))], "view/render"),
        ([.send(render(tab: 1))], "view/render"),
        ([.send(render(tab: 9))], "view/render"),
        ([.send(render(panel: "nope"))], #"panel "nope""#),
        ([.send(#"{"jsonrpc":"2.0","method":"view/render","params":{"tab":0,"panel":"p","root":\#(buttonTree)}}"#)], "exactly one"),
        ([.send(#"{"jsonrpc":"2.0","method":"canvas/regions","params":{"tab":0,"regions":[]}}"#)], "canvas/regions"),
        ([.present(tab: 0, length: 16, width: 2)], "view tab"),
    ])
    func malformedOrMisdirectedViewMessagesStopThePlugin(steps: [PluginFixtureStep], fragment: String) async throws {
        let host = try makeHost([[.send(activateOK)] + steps], manifest: Self.viewManifest)
        await host.activate()
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains(fragment))
    }

    @Test func viewEventsOnlyReachNodesInTheCurrentTree() async throws {
        let host = try makeHost(
            [[.send(activateOK), .send(render()), .send(render(panel: "p", #"{"id":"side","kind":"button","label":"S"}"#))]],
            manifest: Self.viewManifest)
        await host.activate()
        await host.viewEvent(tab: 0, id: "nope", kind: "click", value: nil)
        await host.viewEvent(tab: 0, id: "go", kind: "click", value: nil)
        // Each tree answers only for its own nodes.
        await host.viewEvent(place: PluginPanelPlace(panel: "p"), id: "go", kind: "click", value: nil)
        await host.viewEvent(place: PluginPanelPlace(panel: "p"), id: "side", kind: "click", value: nil)
        let events = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("view/event") }.map(\.text)
        try #require(events.count == 2)
        #expect(events[0].contains(#""id":"go""#) && events[0].contains(#""tab":0"#) && !events[0].contains("panel"))
        #expect(events[1].contains(#""id":"side""#) && events[1].contains(#""panel":"p""#) && !events[1].contains("tab"))
    }

    /// Sent when the first place shows the panel and when the last one stops, and again to a restarted instance.
    @Test func panelVisibilityIsSentOnTransitionsAndToANewInstance() async throws {
        let host = try makeHost([[.send(activateOK)]], manifest: Self.viewManifest)
        func sent() -> [Bool] {
            host.trace.filter { $0.direction == .toPlugin && $0.text.contains("panel/visible") }
                .map { $0.text.contains(#""visible":true"#) }
        }
        await host.activate()
        await host.setPanelVisible("p", true)?.value
        await host.setPanelVisible("p", true)?.value
        await host.setPanelVisible("nope", true)?.value
        await host.setPanelVisible("p", false)?.value
        await host.setPanelVisible("p", false)?.value
        await host.setPanelVisible("p", true)?.value
        #expect(sent() == [true, false, true])
        await host.deactivate()
        await host.activate()
        #expect(sent() == [true])

        // Shown and hidden at once, without waiting: the count is settled before either delivery runs, so a
        // restart afterwards does not think the panel is on screen.
        host.setPanelVisible("p", false)
        host.setPanelVisible("p", true)
        await host.setPanelVisible("p", false)?.value
        await host.deactivate()
        await host.activate()
        #expect(sent().isEmpty)
    }

    @Test func taskStartNeedsTheGrant() async throws {
        let recorder = Recorder()
        let host = try makeHost([[.send(activateOK), .send(taskStart())]], recorder: recorder, manifest: Self.viewManifest)
        await host.activate()
        #expect(lastReply(host)?.contains(#""code":-32001"#) == true)
        #expect(recorder.tasks.isEmpty)
    }

    /// The gate reopens on success and on failure, and a stale completion is ignored.
    @Test func taskStartAllowsOneInFlightAndReopens() async throws {
        let recorder = Recorder()
        let host = try makeHost(
            [[.send(activateOK), .send(taskStart(id: 1)), .send(taskStart(id: 2))], [], [], [.send(taskStart(id: 3))]],
            grants: [.tasksStart, .workspaceRead], recorder: recorder, manifest: Self.viewManifest)
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
            grants: [.tasksStart], recorder: recorder, manifest: Self.viewManifest)
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
            grants: [.tasksStart], recorder: recorder, limits: limits, manifest: Self.viewManifest)
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
        ]], manifest: Self.viewManifest, storage: storage)
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

    // MARK: - API 5

    static let commandManifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":5,"entry":"p.js","contributes":{"commands":[{"id":"fix","title":"Fix","slots":["toolbar"]}]}}"#

    @Test func onlyDeclaredCommandsRunAndCarryTheirTarget() async throws {
        let host = try makeHost([[.send(activateOK)]], manifest: Self.commandManifest)
        await host.activate()
        await host.runCommand("nope", target: .project)
        await host.runCommand("fix", target: .worktree("w1"))
        let runs = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("command/run") }
        #expect(runs.count == 1)
        #expect(runs.first?.text.contains(#""command":"fix""#) == true)
        // JSONEncoder does not fix key order, so check the target's fields one by one.
        #expect(runs.first.map { $0.text.contains(#""kind":"worktree""#) && $0.text.contains(#""worktree":"w1""#) } == true)
    }

    private static func notify(_ title: String, body: String = "b") -> PluginFixtureStep {
        .send(#"{"jsonrpc":"2.0","method":"notify","params":{"title":"\#(title)","body":"\#(body)"}}"#)
    }

    @Test func notifyWithoutTheGrantIsDroppedWithOneWarning() async throws {
        let recorder = Recorder()
        let host = try makeHost([[.send(activateOK), Self.notify("a"), Self.notify("b")]], recorder: recorder)
        await host.activate()
        #expect(host.state == .active)
        #expect(recorder.notes.isEmpty)
        #expect(host.log.map(\.level) == ["warn"])
    }

    /// One per two seconds, bounded and named after the plugin; the rest are dropped, not queued.
    @Test func notifyIsBoundedAndRateLimited() async throws {
        let recorder = Recorder()
        var time = ContinuousClock.now
        let host = try makeHost(
            [
                [.send(activateOK), Self.notify(String(repeating: "t", count: 100), body: String(repeating: "x", count: 600)), Self.notify("dropped")],
                [Self.notify("too soon")],
                [Self.notify("later")],
            ],
            grants: [.notify, .workspaceRead], recorder: recorder, now: { time })
        await host.activate()
        time += .seconds(1)
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        time += .milliseconds(1500)
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        #expect(recorder.notes == [
            "Test: \(String(repeating: "t", count: 80))|\(String(repeating: "x", count: 500))",
            "Test: later|b",
        ])
    }

    /// Only the events the manifest lists, and each only with its own grant.
    @Test(arguments: [
        (Set<PluginCapability>(), [String]()),
        (Set<PluginCapability>([.sessionRead]), ["session/finished"]),
        (Set<PluginCapability>([.sessionRead, .runsRead]), ["session/finished", "run/finished"]),
    ] as [(Set<PluginCapability>, [String])])
    func eventsNeedTheSubscriptionAndTheirGrant(grants: Set<PluginCapability>, methods: [String]) async throws {
        let manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":6,"entry":"p.js","capabilities":["session.read","runs.read"],"events":["session.finished","run.finished"]}"#
        let host = try makeHost([[.send(activateOK)]], grants: grants, manifest: manifest)
        await host.activate()
        await host.events([
            PluginEventMessage(event: .sessionState, params: PluginEventParams(session: "s1", worktree: "w", state: "idle")),
            PluginEventMessage(event: .sessionFinished, params: PluginEventParams(session: "s1", worktree: "w")),
            PluginEventMessage(event: .runFinished, params: PluginEventParams(worktree: "w", script: "repo:a", run: "r1", exitCode: 0)),
        ])
        let sent = host.trace.filter { $0.direction == .toPlugin && $0.text.contains(#""method":"#) && !$0.text.contains("alas/") }
            .map(\.text)
        #expect(sent.map { $0.firstMatch(of: /"method":"([^"]+)"/).map { String($0.1) } ?? "" } == methods)
        #expect(sent.allSatisfy { !$0.contains("state") })
    }

    // MARK: - API 5: settings, network, timers

    /// Holds every request until the test answers it.
    final class FakeTransport: PluginHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(request: URLRequest, redirectHosts: [String])] = []
        private var pending: [CheckedContinuation<(Data, HTTPURLResponse), any Error>] = []

        var requests: [(request: URLRequest, redirectHosts: [String])] { lock.withLock { seen } }

        func data(for request: URLRequest, redirectHosts: [String]) async throws -> (Data, HTTPURLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    seen.append((request, redirectHosts))
                    pending.append(continuation)
                }
            }
        }

        /// Answers the oldest unanswered request.
        func respond(_ body: String = "ok") {
            let continuation = lock.withLock { pending.removeFirst() }
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.com")!, statusCode: 200, httpVersion: nil, headerFields: ["X-A": "1"])!
            continuation.resume(returning: (Data(body.utf8), response))
        }
    }

    /// A clock that only moves when the test fires it. Cancelling a sleeper wakes it with an error, as `Task.sleep` does.
    final class Sleeper: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
        private var slept: [Duration] = []
        private var cancelled = 0

        var waiting: Int { lock.withLock { pending.count } }
        var durations: [Duration] { lock.withLock { slept } }
        var cancellations: Int { lock.withLock { cancelled } }

        func sleep(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.withLock {
                        pending[id] = continuation
                        slept.append(duration)
                    }
                    if Task.isCancelled { cancel(id) }
                }
            } onCancel: {
                cancel(id)
            }
        }

        private func cancel(_ id: UUID) {
            let continuation = lock.withLock {
                let continuation = pending.removeValue(forKey: id)
                if continuation != nil { cancelled += 1 }
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }

        func fireAll() {
            let due = lock.withLock {
                defer { pending = [:] }
                return pending.values
            }
            for continuation in due { continuation.resume() }
        }
    }

    static let integrationManifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":5,"entry":"p.js","capabilities":["network","timers"],"network":["api.example.com","other.example.com"],"settings":[{"key":"team","title":"Team","type":"string","default":"eng"},{"key":"on","title":"On","type":"bool"},{"key":"token","title":"Token","type":"secret","hosts":["api.example.com"]}]}"#

    @Test func settingsGetAndChangedCarryPlainValuesButNeverSecrets() async throws {
        let manifest = try PluginManifest.parse(Data(Self.integrationManifest.utf8))
        let settings = Self.settings(manifest)
        settings.setSecret("token", "s3cret")
        let host = try makeHost(
            [[.send(activateOK), .send(request(1, "settings/get", "{}"))]],
            manifest: Self.integrationManifest, settings: settings)
        await host.activate()
        let reply = try #require(lastReply(host))
        #expect(reply.contains(#""team":"eng""#) && reply.contains(#""on":false"#))
        settings.set("team", .string("ops"))
        // Oversized values are refused, so every settings message fits and every header stays bounded.
        settings.set("team", .string(String(repeating: "x", count: PluginSettings.maxStringBytes + 1)))
        #expect(settings.string("team") == "ops")
        #expect(!settings.setSecret("token", String(repeating: "x", count: PluginSettings.maxStringBytes + 1)))
        #expect(settings.secret("token") == "s3cret")
        await host.settingsChanged()
        let changed = try #require(lastReply(host))
        #expect(changed.contains("settings/changed") && changed.contains(#""team":"ops""#))
        // A plugin learns that a secret is set, never what it is.
        #expect([reply, changed].allSatisfy { $0.contains(#""secretsSet":["token"]"#) && !$0.contains("s3cret") })
    }

    struct FetchCase: Sendable {
        let request: String
        /// nil: the request goes out.
        let refusal: String?
        var authorization: String?
    }

    @Test(arguments: [
        FetchCase(request: fetch(url: "http://api.example.com/x"), refusal: #""code":-32602"#),
        FetchCase(request: fetch(url: "https://evil.example.com/x"), refusal: #""code":-32001"#),
        FetchCase(request: fetch(url: "https://api.example.com:8443/x"), refusal: #""code":-32001"#),
        FetchCase(
            request: fetch(url: "https://other.example.com/x", auth: "Bearer {{secret:token}}"),
            refusal: "secret token is not allowed for other.example.com"),
        FetchCase(request: fetch(auth: "Bearer {{secret:nope}}"), refusal: #""code":-32602"#),
        FetchCase(request: fetch(auth: "Bearer {{secret:token}}"), refusal: nil, authorization: "Bearer s3cret"),
        FetchCase(request: fetch(auth: String(repeating: "{{secret:token}}", count: 9)), refusal: "more than 8 secret substitutions"),
    ])
    func fetchGoesOnlyToListedHostsAndSecretsOnlyToTheirs(_ c: FetchCase) async throws {
        let manifest = try PluginManifest.parse(Data(Self.integrationManifest.utf8))
        let settings = Self.settings(manifest)
        settings.setSecret("token", "s3cret")
        let transport = FakeTransport()
        let host = try makeHost(
            [[.send(activateOK), .send(c.request)]], grants: [.network],
            manifest: Self.integrationManifest, settings: settings, transport: transport)
        await host.activate()
        if let refusal = c.refusal {
            #expect(lastReply(host)?.contains(refusal) == true)
            #expect(transport.requests.isEmpty)
            return
        }
        #expect(await awaitCondition { transport.requests.count == 1 })
        let sent = try #require(transport.requests.first)
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == c.authorization)
        // The secret's hosts also bound where a redirect may take it.
        #expect(sent.redirectHosts == ["api.example.com"])
        transport.respond("hello")
        #expect(await awaitCondition { lastReply(host)?.contains(#""body":"hello""#) == true })
        #expect(lastReply(host)?.contains(#""status":200"#) == true)
    }

    /// Four in flight per instance; a reply goes to the instance that asked, in a later delivery.
    @Test func fetchRepliesComeLaterAndOnlyToTheInstanceThatAsked() async throws {
        let transport = FakeTransport()
        let host = try makeHost(
            [[.send(activateOK)] + (1...5).map { .send(fetch($0)) }], grants: [.network],
            manifest: Self.integrationManifest, transport: transport)
        await host.activate()
        #expect(replies(host).last?.contains("too many requests in flight") == true)
        #expect(await awaitCondition { transport.requests.count == 4 })
        transport.respond("first")
        #expect(await awaitCondition { lastReply(host)?.contains(#""body":"first""#) == true })

        await host.deactivate()
        await host.activate()
        // The new instance starts with nothing in flight, so it gets four of its own.
        #expect(await awaitCondition { transport.requests.count == 8 })
        for _ in 0..<3 { transport.respond("stale") }
        transport.respond("fresh")
        #expect(await awaitCondition { lastReply(host)?.contains(#""body":"fresh""#) == true })
        #expect(!host.trace.contains { $0.text.contains("stale") })
    }

    @Test func aRepeatingTimerFiresOnTheClockUntilCancelled() async throws {
        let sleeper = Sleeper()
        let host = try makeHost(
            [
                [.send(activateOK), .send(request(1, "timer/set", #"{"id":"a","seconds":60,"repeat":true}"#))],
                [],
                [],
                [.send(request(2, "timer/cancel", #"{"id":"a"}"#))],
            ],
            grants: [.timers, .workspaceRead], manifest: Self.integrationManifest, sleeper: sleeper)
        await host.activate()
        #expect(await awaitCondition { sleeper.waiting == 1 })
        sleeper.fireAll()
        #expect(await awaitCondition { sleeper.waiting == 1 && sleeper.durations.count == 2 })
        #expect(host.trace.filter { $0.text.contains("timer/fired") }.count == 1)
        #expect(sleeper.durations == [.seconds(60), .seconds(60)])
        // The plugin cancels while the timer sleeps again.
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        #expect(await awaitCondition { sleeper.cancellations == 1 })
        #expect(sleeper.waiting == 0)
    }

    @Test func timersAreBoundedAndDieWithTheInstance() async throws {
        let sleeper = Sleeper()
        var limits = Self.limits
        limits.maxSendsPerCall = 16
        let set = #"for (let i = 1; i <= 9; i++) alas.send(JSON.stringify({jsonrpc: "2.0", id: i, method: "timer/set", params: {id: "t" + i, seconds: 60}}));"#
        let host = try makeHost(
            [[.send(activateOK), .script(set), .send(request(10, "timer/set", #"{"id":"short","seconds":59}"#))]],
            grants: [.timers], limits: limits, manifest: Self.integrationManifest, sleeper: sleeper)
        await host.activate()
        let sent = replies(host)
        #expect(sent.filter { $0.contains(#""result":{}"#) }.count == 8)
        #expect(sent.contains { $0.contains(#""id":9"#) && $0.contains("at most 8 timers") })
        #expect(sent.contains { $0.contains(#""id":10"#) && $0.contains(#""code":-32602"#) })
        #expect(await awaitCondition { sleeper.waiting == 8 })
        await host.deactivate()
        #expect(await awaitCondition { sleeper.cancellations == 8 })
    }

    // MARK: - API 6

    struct DecorationCase: Sendable {
        let step: PluginFixtureStep
        var manifest = api6Manifest
        /// "text|tone|command" for each item on worktree "wt"'s row, or nil when the plugin stops.
        let items: [String]?
        var warns = 0
    }

    /// Caps and checks of one `decorations/set`: at most two items, text cut to 24 scalars, only rows of the project,
    /// and only declared commands and known tones.
    @Test(arguments: [
        DecorationCase(
            step: decorate("worktree.row", target: "wt", #"{"text":"CI \#(String(repeating: "x", count: 30))","tone":"danger","command":"fix"},{"text":"b"},{"text":"c"}"#),
            items: ["CI \(String(repeating: "x", count: 21))|danger|fix", "b||"]),
        DecorationCase(step: decorate("worktree.row", target: "gone", #"{"text":"a"}"#), items: [], warns: 1),
        DecorationCase(step: decorate("sidebar.row", target: "wt", #"{"text":"a"}"#), items: [], warns: 1),
        DecorationCase(step: decorate("worktree.row", target: "wt", #"{"text":"a","command":"nope"}"#), items: nil),
        DecorationCase(step: decorate("worktree.row", target: "wt", #"{"text":"a","tone":"pink"}"#), items: nil),
        DecorationCase(step: decorate("run.row", target: "repo:dev.sh", #"{"text":"a"}"#), items: nil),
        DecorationCase(step: decorate("worktree.row", target: "wt", #"{"text":"a"}"#), manifest: api5Manifest, items: []),
    ])
    func decorationsAreCappedAndScopedToTheProject(_ c: DecorationCase) async throws {
        let host = try makeHost([[.send(activateOK), c.step]], manifest: c.manifest)
        await host.activate()
        guard let expected = c.items else {
            #expect(host.state != .active)
            return
        }
        #expect(host.state == .active)
        let items = host.decorations[PluginDecorationKey(slot: .worktreeRow, target: "wt")] ?? []
        #expect(items.map { "\($0.text)|\($0.tone?.rawValue ?? "")|\($0.command ?? "")" } == expected)
        #expect(host.log.filter { $0.level == "warn" }.count == c.warns)
    }

    /// Setting replaces that row's items, no items clear them, and stopping the plugin clears everything.
    @Test func decorationsReplaceAndClearWithTheInstance() async throws {
        let host = try makeHost(
            [
                [.send(activateOK), decorate("worktree.row", target: "wt", #"{"text":"a"}"#),
                 decorate("worktree.row", target: "wt", #"{"text":"b"}"#),
                 decorate("changes.file", target: "a.swift", worktree: "wt", #"{"text":"lint"}"#),
                 decorate("repo.row", target: "proj", #"{"text":"p"}"#)],
                [decorate("changes.file", target: "a.swift", worktree: "wt", "")],
            ],
            grants: [.workspaceRead], manifest: api6Manifest)
        await host.activate()
        #expect(host.decorations[PluginDecorationKey(slot: .worktreeRow, target: "wt")]?.map(\.text) == ["b"])
        #expect(host.decorations.count == 3)
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        #expect(host.decorations[PluginDecorationKey(slot: .changesFile, worktree: "wt", target: "a.swift")] == nil)
        #expect(host.decorations.count == 2)
        await host.deactivate()
        #expect(host.decorations.isEmpty)
    }

    /// A panel at a location with a worktree or run must name it, and shows only for that place and while not empty.
    @Test func inlinePanelsRenderForTheirPlaceAndHideWhileEmpty() async throws {
        let checks = PluginPanelPlace(panel: "checks", worktree: "wt")
        let host = try makeHost(
            [[.send(activateOK),
              .send(#"{"jsonrpc":"2.0","method":"view/render","params":{"panel":"checks","worktree":"wt","root":\#(buttonTree)}}"#)],
             [.send(#"{"jsonrpc":"2.0","method":"view/render","params":{"panel":"checks","worktree":"wt","root":{"id":"r","kind":"vstack","children":[]}}}"#)],
             [.send(render(panel: "explain"))]],
            grants: [.workspaceRead], manifest: api6Manifest)
        await host.activate()
        #expect(host.panelTree(for: checks)?.id == "root")
        #expect(host.panelTree(for: PluginPanelPlace(panel: "checks", worktree: "other")) == nil)
        // A click from a tree rendered for another worktree is dropped, not credited to this one.
        await host.viewEvent(place: PluginPanelPlace(panel: "checks", worktree: "other"), id: "go", kind: "click", value: nil)
        await host.viewEvent(place: checks, id: "go", kind: "click", value: nil)
        let clicks = host.trace.filter { $0.direction == .toPlugin && $0.text.contains("view/event") }.map(\.text)
        #expect(clicks.count == 1 && clicks[0].contains(#""worktree":"wt""#))
        // Shown for a run: the plugin hears which one, and re-renders the section empty.
        await host.setPanelVisible(PluginPanelPlace(panel: "explain", run: "r1"), true)?.value
        #expect(host.trace.contains { $0.text.contains("panel/visible") && $0.text.contains(#""run":"r1""#) })
        #expect(host.panelTree(for: checks) == nil)
        // The run report section needs its run.
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        guard case .failed(let reason) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(reason.contains("needs run"))
    }

    struct API6RequestCase: Sendable {
        let request: String
        var grants: Set<PluginCapability> = [.sessionWrite, .runsStart, .runsRead, .reviewWrite]
        var manifest = api6Manifest
        let reply: String
        /// What reached the app: "sent", "runs" or "comments" entries.
        var acted: [String] = []
    }

    /// Each request is checked against its grant and bounded before anything is acted on.
    @Test(arguments: [
        API6RequestCase(request: request(1, "session/send", #"{"session":"s1","text":"hi"}"#), grants: [], reply: #""code":-32001"#),
        API6RequestCase(request: request(1, "session/send", #"{"session":"s1","text":"hi"}"#), manifest: api5Manifest, reply: #""code":-32601"#),
        API6RequestCase(request: request(1, "session/send", #"{"session":"s1","text":"hi"}"#), reply: #""result":{}"#, acted: ["s1|hi"]),
        API6RequestCase(request: request(1, "session/send", #"{"session":"other","text":"hi"}"#), reply: #""code":-32003"#, acted: ["other|hi"]),
        API6RequestCase(request: request(1, "session/send", #"{"session":"s1","text":" "}"#), reply: #""code":-32602"#),
        API6RequestCase(request: request(1, "run/start", #"{"worktree":"wt","script":"repo:dev.sh"}"#), reply: #""result":{}"#, acted: ["wt|repo:dev.sh"]),
        API6RequestCase(request: request(1, "run/start", #"{"worktree":"wt","script":"repo:nope"}"#), reply: "unknown run script", acted: ["wt|repo:nope"]),
        API6RequestCase(request: request(1, "run/output", #"{"run":"live"}"#), reply: "has not finished"),
        API6RequestCase(request: request(1, "run/output", #"{"run":"gone"}"#), reply: "unknown run gone"),
        API6RequestCase(request: request(1, "review/comment", #"{"worktree":"wt","path":"a/b.swift","line":3,"body":"Nit"}"#), reply: #""result":{}"#, acted: ["Test|wt|a/b.swift|3"]),
        API6RequestCase(request: request(1, "review/comment", #"{"worktree":"wt","path":"../b.swift","line":3,"body":"Nit"}"#), reply: #""code":-32602"#),
        API6RequestCase(request: request(1, "review/comment", #"{"worktree":"wt","path":"a.swift","line":0,"body":"Nit"}"#), reply: #""code":-32602"#),
        API6RequestCase(request: request(1, "review/comment", #"{"worktree":"wt","path":"a.swift","line":1,"body":"\#(String(repeating: "x", count: 16 * 1024 + 1))"}"#), reply: #""code":-32602"#),
    ])
    func api6RequestsAreGatedAndBounded(_ c: API6RequestCase) async throws {
        let recorder = Recorder()
        var limits = Self.limits
        limits.maxMessageBytes = 1 << 17
        let host = try makeHost([[.send(activateOK), .send(c.request)]], grants: c.grants, recorder: recorder, limits: limits, manifest: c.manifest)
        await host.activate()
        #expect(await awaitCondition { replies(host).count == 2 })
        #expect(host.state == .active)
        #expect(lastReply(host)?.contains(c.reply) == true)
        #expect(recorder.sent + recorder.runsStarted + recorder.comments == c.acted)
    }

    @Test func endingAnInstanceKeepsTheWorkItAskedForButDropsTheReply() async throws {
        let recorder = Recorder()
        let host = try makeHost(
            [[.send(activateOK), .send(request(1, "run/start", #"{"worktree":"wt","script":"repo:slow.sh"}"#))]],
            grants: [.runsStart], recorder: recorder, manifest: api6Manifest)
        await host.activate()
        #expect(await awaitCondition { recorder.slowRun != nil })
        let repliesBefore = replies(host).count
        await host.deactivate()
        recorder.slowRun?.resume()
        #expect(await awaitCondition { recorder.slowRunCancelled != nil })
        #expect(recorder.slowRunCancelled == false)
        #expect(replies(host).count == repliesBefore)
    }

    /// `run/output` keeps the tail, starting on a scalar boundary.
    @Test(arguments: [(5, "aéx"), (3, "éx"), (2, "x")])
    func runOutputKeepsTheTail(maxBytes: Int, output: String) {
        #expect(PluginRunOutputResult.tail("aéx", maxBytes: maxBytes) == PluginRunOutputResult(output: output, truncated: output != "aéx"))
    }

    // MARK: - API 6: processes and files

    /// Holds every process until the test makes it print and exit.
    final class FakeLauncher: PluginProcessLauncher, @unchecked Sendable {
        final class Handle: PluginProcessHandle, @unchecked Sendable {
            let argv: [String]
            let directory: URL
            let events: AsyncStream<PluginProcessEvent>
            private let continuation: AsyncStream<PluginProcessEvent>.Continuation
            private let lock = NSLock()
            private var sent: [Int32] = []

            var signals: [Int32] { lock.withLock { sent } }

            init(argv: [String], directory: URL) {
                self.argv = argv
                self.directory = directory
                (events, continuation) = AsyncStream.makeStream()
            }

            func terminate() { lock.withLock { sent.append(SIGTERM) } }
            func kill() { lock.withLock { sent.append(SIGKILL) } }

            func emit(_ events: PluginProcessEvent...) {
                for event in events { continuation.yield(event) }
                if case .exit? = events.last { continuation.finish() }
            }
        }

        private let lock = NSLock()
        private var launched: [Handle] = []

        var handles: [Handle] { lock.withLock { launched } }

        func launch(
            _ argv: [String], in directory: URL, stdin: Data?, keep: PluginProcessOutput.Keep, limit: Int
        ) throws -> any PluginProcessHandle {
            let handle = Handle(argv: argv, directory: directory)
            lock.withLock { launched.append(handle) }
            return handle
        }
    }

    static let processManifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":6,"entry":"p.js","capabilities":["process.exec","files.read","files.write"],"processes":[{"id":"install","command":["pnpm","install"]},{"id":"op","command":["op","read"],"appendArgs":true},{"id":"dev","command":["pnpm","dev"],"longRunning":true}]}"#

    struct ProcessCase: Sendable {
        let request: String
        var grants: Set<PluginCapability> = [.processExec]
        /// Part of the immediate reply; nil when `process/run` goes out and answers later.
        let reply: String?
        var argv: [String]? = nil
    }

    /// The argv is exactly the manifest's, plus args only where it allows them, in a worktree of the project.
    @Test(arguments: [
        ProcessCase(request: processCall(1), grants: [], reply: #""code":-32001"#),
        ProcessCase(request: processCall(1), reply: nil, argv: ["pnpm", "install"]),
        ProcessCase(request: processCall(1, args: ["x"]), reply: "takes no args"),
        ProcessCase(request: processCall(1, "process/run", "op", args: ["x", "y"]), reply: nil, argv: ["op", "read", "x", "y"]),
        ProcessCase(request: processCall(1, "process/run", "op", args: Array(repeating: "x", count: 33)), reply: #""code":-32602"#),
        ProcessCase(request: processCall(1, "process/run", "op", args: [String(repeating: "x", count: 1025)]), reply: #""code":-32602"#),
        ProcessCase(request: processCall(1, "process/run", "nope"), reply: "unknown process nope"),
        ProcessCase(request: processCall(1, "process/run", "dev"), reply: "use process/start"),
        ProcessCase(request: processCall(1, "process/start", "install"), reply: "use process/run"),
        ProcessCase(request: processCall(1, worktree: "other"), reply: "unknown worktree other"),
        ProcessCase(request: processCall(1, "process/start", "dev"), reply: #""run":"p1""#, argv: ["pnpm", "dev"]),
    ])
    func processesRunOnlyWhatTheManifestDeclares(_ c: ProcessCase) async throws {
        let launcher = FakeLauncher()
        let host = try makeHost([[.send(activateOK), .send(c.request)]], grants: c.grants, manifest: Self.processManifest, launcher: launcher)
        await host.activate()
        #expect(host.state == .active)
        if let reply = c.reply {
            #expect(lastReply(host)?.contains(reply) == true)
        } else {
            #expect(replies(host).count == 1)
        }
        #expect(launcher.handles.first?.argv == c.argv)
        #expect(launcher.handles.allSatisfy { $0.directory.path == "/tmp/wt" })
    }

    /// Two at a time, output capped, and an instance that ends stops its processes and never hears from them.
    @Test func processRunRepliesWithCappedOutputOnlyToItsInstance() async throws {
        let launcher = FakeLauncher()
        let sleeper = Sleeper()
        var limits = Self.limits
        // Output is capped at half of it, so the whole reply shows in the trace.
        limits.maxMessageBytes = 2048
        let host = try makeHost(
            [[.send(activateOK), .send(processCall(1)), .send(processCall(2)), .send(processCall(3))]],
            grants: [.processExec], limits: limits, manifest: Self.processManifest, sleeper: sleeper, launcher: launcher)
        await host.activate()
        #expect(lastReply(host)?.contains("at most 2 processes running") == true)
        #expect(launcher.handles.count == 2)

        launcher.handles[0].emit(.stdout(Data(repeating: 0x78, count: 1000)), .stdout(Data(repeating: 0x78, count: 100)), .stderr(Data("e".utf8)), .exit(3))
        #expect(await awaitCondition { lastReply(host)?.contains(#""exit":3"#) == true })
        let reply = try #require(lastReply(host))
        #expect(reply.contains(#""truncated":true"#) && reply.contains(#""stderr":"""#))
        #expect(reply.contains(#""stdout":""# + String(repeating: "x", count: 1024) + "\""))

        await host.deactivate()
        #expect(launcher.handles[1].signals == [SIGTERM])
        // The finished run's time limit is cancelled; the stopped run's lasts until it exits, next to the kill grace.
        #expect(await awaitCondition { sleeper.cancellations == 1 && sleeper.waiting == 2 })
        sleeper.fireAll()
        #expect(await awaitCondition { launcher.handles[1].signals.contains(SIGKILL) })
        // The next instance hears only about its own runs.
        await host.activate()
        launcher.handles[1].emit(.exit(137))
        launcher.handles[2].emit(.exit(0))
        #expect(await awaitCondition { lastReply(host)?.contains(#""exit":0"#) == true })
        #expect(!host.trace.contains { $0.text.contains(#""exit":137"#) })
    }

    /// Control characters escape to six bytes each, so the output is cut until the reply fits rather than the
    /// whole result being refused.
    @Test func processRunReplyAlwaysCarriesTheExitStatus() async throws {
        let launcher = FakeLauncher()
        var limits = Self.limits
        limits.maxMessageBytes = 1024
        let host = try makeHost(
            [[.send(activateOK), .send(processCall(1))]], grants: [.processExec], limits: limits,
            manifest: Self.processManifest, launcher: launcher)
        await host.activate()
        launcher.handles[0].emit(.stdout(Data(repeating: 0x01, count: 500)), .exit(5))
        #expect(await awaitCondition { lastReply(host)?.contains(#""exit":5"#) == true })
        let reply = try #require(lastReply(host))
        #expect(reply.contains(#""truncated":true"#) && reply.contains(#"\u0001"#))
        #expect(reply.utf8.count <= 1024)
    }

    /// Output is bounded where it is produced, and the reader gets it as one batch, then the truncation, then the exit.
    @Test(arguments: [(PluginProcessOutput.Keep.head, "abcd"), (.tail, "cdef")])
    func processOutputIsBoundedBeforeTheReaderSeesIt(keep: PluginProcessOutput.Keep, kept: String) async {
        let output = PluginProcessOutput(keep: keep, limit: 4, interval: .zero)
        output.append(Data("abc".utf8), stream: 0)
        output.append(Data("def".utf8), stream: 0)
        output.append(Data("e".utf8), stream: 1)
        output.finish(exit: 3)
        var events: [PluginProcessEvent] = []
        for await event in output.events { events.append(event) }
        #expect(events == [.stdout(Data(kept.utf8)), .stderr(Data("e".utf8)), .truncated, .exit(3)])
    }

    @Test(arguments: [
        (["git", "status"], "git status"),
        (["sh", "-c", "a b"], #"sh -c "a b""#),
        (["x", ""], #"x """#),
        (["echo", "a\nApprove everything"], #"echo "a\u{a}Approve everything""#),
        (["echo", "\u{202E}txt.exe", #"q"\"#], #"echo "\u{202e}txt.exe" "q\"\\""#),
    ])
    func argvDisplayKeepsEveryArgumentDistinct(argv: [String], shown: String) {
        #expect(PluginArgv.display(argv) == shown)
    }

    /// Bytes split anywhere, a multibyte character included, read the same once joined; a character the limit cuts
    /// at the front is left out.
    @Test(arguments: [(1, 64, "aé€b"), (2, 64, "aé€b"), (4, 64, "aé€b"), (3, 5, "€b")])
    func processRunOutputDecodesAcrossBatches(chunk: Int, limit: Int, shown: String) {
        var run = PluginProcessRun(id: "p1", process: "x", worktree: "wt", command: [])
        let bytes = Array("aé€b".utf8)
        for start in stride(from: 0, to: bytes.count, by: chunk) {
            run.append(Data(bytes[start..<min(start + chunk, bytes.count)]), keeping: limit)
        }
        #expect(run.output == shown)
    }

    @Test func processOutputKeepsTheOrderItArrivedIn() async {
        let output = PluginProcessOutput(keep: .tail, limit: 4, interval: .zero)
        output.append(Data("e1".utf8), stream: 1)
        output.append(Data("o1".utf8), stream: 0)
        output.append(Data("e2345".utf8), stream: 1)
        output.finish(exit: 0)
        var events: [PluginProcessEvent] = []
        for await event in output.events { events.append(event) }
        // stderr's oldest bytes go first to keep its latest four; the order across streams holds.
        #expect(events == [.stdout(Data("o1".utf8)), .stderr(Data("2345".utf8)), .truncated, .exit(0)])
    }

    /// Stopping reaches a child that left the process group, which a group signal alone would miss.
    @Test func stoppingAProcessStopsWhatItStarted() async throws {
        let handle = try PluginFoundationLauncher().launch(
            ["/bin/sh", "-c", "set -m; sleep 30 & echo $!; wait"], in: FileManager.default.temporaryDirectory, stdin: nil,
            keep: .head, limit: 1024)
        var iterator = handle.events.makeAsyncIterator()
        guard case .stdout(let data)? = await iterator.next(),
              let child = pid_t(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            Issue.record("expected the child's pid")
            return
        }
        handle.terminate()
        while await iterator.next() != nil {}
        #expect(await awaitCondition { Darwin.kill(child, 0) != 0 })
    }

    /// A command that exits on its own takes what it left running with it.
    @Test func aProcessThatExitsStopsWhatItLeftBehind() async throws {
        let handle = try PluginFoundationLauncher().launch(
            ["/bin/sh", "-c", "sleep 0.2; sleep 30 & echo $!"], in: FileManager.default.temporaryDirectory, stdin: nil,
            keep: .head, limit: 1024)
        var child: pid_t?
        for await event in handle.events {
            if case .stdout(let data) = event {
                child = pid_t(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let pid = try #require(child)
        #expect(await awaitCondition { Darwin.kill(pid, 0) != 0 })
    }

    @Test func processRunIsStoppedThenKilledAtTheTimeLimit() async throws {
        let launcher = FakeLauncher()
        let sleeper = Sleeper()
        let host = try makeHost(
            [[.send(activateOK), .send(processCall(1))]], grants: [.processExec], manifest: Self.processManifest,
            sleeper: sleeper, launcher: launcher)
        await host.activate()
        #expect(await awaitCondition { sleeper.waiting == 1 })
        sleeper.fireAll()
        #expect(await awaitCondition { launcher.handles.first?.signals == [SIGTERM] && sleeper.waiting == 1 })
        sleeper.fireAll()
        #expect(await awaitCondition { launcher.handles.first?.signals == [SIGTERM, SIGKILL] })
        launcher.handles[0].emit(.exit(137))
        #expect(await awaitCondition { lastReply(host)?.contains(#""timedOut":true"#) == true })
        #expect(sleeper.durations == [PluginHost.processTimeout, PluginHost.processKillGrace])
    }

    /// A long-running process shows in the Run tab with its output, stops from there, reports its exit, and
    /// stops with the plugin.
    @Test func longRunningProcessesAreVisibleStoppableAndEndWithThePlugin() async throws {
        let launcher = FakeLauncher()
        let host = try makeHost(
            [[.send(activateOK), .send(processCall(1, "process/start", "dev"))], [], [.send(processCall(2, "process/start", "dev"))]],
            grants: [.processExec], manifest: Self.processManifest, launcher: launcher)
        await host.activate()
        #expect(host.processRuns.map(\.id) == ["p1"])
        launcher.handles[0].emit(.stdout(Data("ready".utf8)))
        #expect(await awaitCondition { host.processRuns.first?.output == "ready" })
        host.stopProcess("p1")
        #expect(launcher.handles[0].signals == [SIGTERM])
        launcher.handles[0].emit(.exit(143))
        // The exit notification is the delivery in which the plugin starts another.
        #expect(await awaitCondition { launcher.handles.count == 2 })
        #expect(host.trace.contains { $0.text.contains("process/exited") && $0.text.contains(#""run":"p1""#) && $0.text.contains(#""exit":143"#) })
        #expect(host.processRuns.map(\.exit) == [143, nil])
        await host.deactivate()
        #expect(launcher.handles[1].signals == [SIGTERM])
    }

    /// One real process: the command is found on `PATH` and gets its stdin.
    @Test func theLauncherFindsCommandsAndFeedsStdin() async throws {
        let handle = try PluginFoundationLauncher().launch(
            ["cat"], in: FileManager.default.temporaryDirectory, stdin: Data("hi".utf8), keep: .head, limit: 1024)
        var events: [PluginProcessEvent] = []
        for await event in handle.events { events.append(event) }
        #expect(events == [.stdout(Data("hi".utf8)), .exit(0)])
    }

    struct FileCase: Sendable {
        let request: String
        var grants: Set<PluginCapability> = [.filesRead, .filesWrite]
        var limits: PluginLimits?
        let reply: String
        var absent: String?
        /// Relative path and content the request leaves in the worktree.
        var written: (String, String)?
    }

    @Test(arguments: [
        FileCase(request: request(1, "file/read", #"{"worktree":"wt","path":"a.txt"}"#), reply: #""content":"hello""#),
        FileCase(request: request(1, "file/read", #"{"worktree":"wt","path":"big.txt"}"#), reply: "larger than 512 KiB"),
        // A file at the limit fits in a reply under the real message limit, newlines escaped and all.
        FileCase(request: request(1, "file/read", #"{"worktree":"wt","path":"edge.txt"}"#), limits: PluginLimits(), reply: #""content":"a\nb"#),
        FileCase(request: request(1, "file/read", #"{"worktree":"wt","path":"bin.dat"}"#), reply: "not UTF-8"),
        FileCase(request: request(1, "file/read", #"{"worktree":"wt","path":"../a.txt"}"#), reply: #""code":-32003"#),
        FileCase(request: request(1, "file/read", #"{"worktree":"other","path":"a.txt"}"#), reply: "unknown worktree other"),
        FileCase(request: request(1, "file/list", #"{"worktree":"wt","dir":""}"#), reply: #""name":"a.txt""#, absent: ".git"),
        FileCase(request: request(1, "file/write", #"{"worktree":"wt","path":"new/dir/b.txt","content":"hi"}"#), grants: [.filesRead], reply: #""code":-32001"#),
        FileCase(request: request(1, "file/write", #"{"worktree":"wt","path":"new/dir/b.txt","content":"hi"}"#), reply: #""result":{}"#, written: ("new/dir/b.txt", "hi")),
        FileCase(request: request(1, "file/write", #"{"worktree":"wt","path":".GIT/config","content":"x"}"#), reply: "inside .git"),
    ])
    func filesStayInsideTheWorktree(_ c: FileCase) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "plugin-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appending(path: "a.txt"))
        try Data(count: PluginFiles.maxFileBytes + 1).write(to: root.appending(path: "big.txt"))
        try Data(String(repeating: "a\nb", count: PluginFiles.maxFileBytes / 3).utf8).write(to: root.appending(path: "edge.txt"))
        try Data([0xFF, 0xFE]).write(to: root.appending(path: "bin.dat"))
        try Data("gitdir: elsewhere".utf8).write(to: root.appending(path: ".git"))
        let host = try makeHost(
            [[.send(activateOK), .send(c.request)]], grants: c.grants, limits: c.limits ?? Self.limits, manifest: Self.processManifest, worktreeRoot: root)
        await host.activate()
        // Counted by direction: the trace keeps only the start of a long reply, which may not reach its id.
        #expect(await awaitCondition { host.trace.filter { $0.direction == .toPlugin }.count == 2 })
        let reply = try #require(host.trace.last { $0.direction == .toPlugin }?.text)
        #expect(reply.contains(c.reply))
        if let absent = c.absent { #expect(!reply.contains(absent)) }
        if let (path, content) = c.written {
            #expect(try String(contentsOf: root.appending(path: path), encoding: .utf8) == content)
        }
        #expect(try String(contentsOf: root.appending(path: ".git"), encoding: .utf8) == "gitdir: elsewhere")
    }

    // MARK: - API 7

    static let api7Manifest = #"{"id":"io.test.plugin","name":"Test","version":"1","api":7,"entry":"p.js","capabilities":["session.context","workspace.read"],"contributes":{"prompts":[{"name":"linear"}]}}"#

    @Test(arguments: [
        ("linear", answer(1, #""result":{"text":"Fix ENG-1"}"#), PluginPromptExpansion.text("Fix ENG-1")),
        ("linear", answer(1, #""error":{"code":-32003,"message":"no such issue"}"#), .failed("Test could not expand /linear: no such issue")),
        ("linear", answer(1, #""result":{"text":" "}"#), .failed("Test expanded /linear to nothing.")),
        ("nope", answer(1, #""result":{"text":"x"}"#), .failed("Unknown prompt /nope.")),
    ] as [(String, PluginFixtureStep, PluginPromptExpansion)])
    func promptExpansionCarriesTheArgsAndTakesTheAnswer(name: String, answer: PluginFixtureStep, expected: PluginPromptExpansion) async throws {
        let host = try makeHost([[.send(activateOK)], [answer]], manifest: Self.api7Manifest)
        await host.activate()
        #expect(await host.expandPrompt(name, args: "ENG-1", session: "s1") == expected)
        if name == "linear" {
            let sent = try #require(host.trace.last { $0.direction == .toPlugin && $0.text.contains("prompt/expand") }?.text)
            #expect(sent.contains(#""name":"linear""#) && sent.contains(#""args":"ENG-1""#) && sent.contains(#""session":"s1""#))
        }
    }

    /// The plugin may answer after its own requests, in a later delivery; past the timeout the prompt is not expanded.
    @Test func promptExpansionWaitsForALaterAnswerUntilTheTimeout() async throws {
        let sleeper = Sleeper()
        let host = try makeHost(
            [[.send(activateOK)], [], [answer(1, #""result":{"text":"Later"}"#)], []],
            grants: [.workspaceRead], manifest: Self.api7Manifest, sleeper: sleeper)
        await host.activate()
        let first = Task { await host.expandPrompt("linear", args: "", session: "s1") }
        #expect(await awaitCondition { sleeper.waiting == 1 })
        // Sending again while it waits does not ask the plugin twice.
        #expect(await host.expandPrompt("linear", args: "", session: "s1") == .busy)
        #expect(host.trace.filter { $0.text.contains("prompt/expand") }.count == 1)
        await host.workspaceChanged(PluginWorkspaceSnapshot(worktrees: []))
        #expect(await first.value == .text("Later"))
        let second = Task { await host.expandPrompt("linear", args: "", session: "s1") }
        #expect(await awaitCondition { sleeper.waiting == 2 })
        #expect(sleeper.durations.last == PluginHost.promptExpandTimeout)
        sleeper.fireAll()
        #expect(await second.value == .failed("Test did not expand /linear."))
    }

    struct ContextCase: Sendable {
        var grants: Set<PluginCapability> = [.sessionContext]
        let step: PluginFixtureStep?
        let expected: String?
        var stops = false
    }

    /// Context is answered within its own delivery or skipped, so the prompt never waits; a plugin over the time limit
    /// stops, and the prompt goes without its context.
    @Test(arguments: [
        ContextCase(step: .send(#"{"jsonrpc":"2.0","id":1,"result":{"text":"Docs"}}"#), expected: "Docs"),
        ContextCase(grants: [], step: .send(#"{"jsonrpc":"2.0","id":1,"result":{"text":"Docs"}}"#), expected: nil),
        ContextCase(step: .send(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32003,"message":"offline"}}"#), expected: nil),
        ContextCase(step: .send(#"{"jsonrpc":"2.0","id":1,"result":{"text":"\#(String(repeating: "x", count: 16 * 1024 + 1))"}}"#), expected: nil),
        ContextCase(step: nil, expected: nil),
        ContextCase(step: .spin, expected: nil, stops: true),
    ])
    func contextIsBoundedAndNeverHoldsThePrompt(_ c: ContextCase) async throws {
        let host = try makeHost(
            [[.send(activateOK)], c.step.map { [$0] } ?? []], grants: c.grants,
            limits: PluginLimits(timePerCall: .milliseconds(100)), manifest: Self.api7Manifest)
        await host.activate()
        #expect(await host.provideContext(session: "s1", worktree: "wt") == c.expected)
        #expect(host.trace.contains { $0.text.contains(#""method":"context/provide""#) } == c.grants.contains(.sessionContext))
        #expect((host.state != .active) == c.stops)
    }

    /// Context providers are asked at once, and their blocks keep plugin order: here each waits for the one after it
    /// to finish, which asking one after another would never get past.
    @Test(.timeLimit(.minutes(1)))
    func contextProvidersAnswerTogetherInPluginOrder() async {
        let gates = (0..<3).map { _ in AsyncStream<Void>.makeStream() }
        @MainActor final class Finished { var value: [Int] = [] }
        let finished = Finished()
        let results = await concurrentlyInOrder(Array(0..<3)) { index in
            if index < 2 { for await _ in gates[index].stream { break } }
            finished.value.append(index)
            if index > 0 { gates[index - 1].continuation.yield() }
            return "\(index)"
        }
        #expect(finished.value == [2, 1, 0])
        #expect(results == ["0", "1", "2"])
    }

    /// A spawned process leads its own process group before it runs anything, and a signal that ends it is reported
    /// as such.
    @Test func aSpawnedProcessLeadsItsOwnGroupFromTheStart() async throws {
        let (ended, ending) = AsyncStream<SpawnedProcess.Termination>.makeStream()
        let process = try SpawnedProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:],
            stdin: nil, stdout: Pipe(), stderr: Pipe()) { _, termination in ending.yield(termination) }
        #expect(getpgid(process.pid) == process.pid)
        process.terminate()
        var iterator = ended.makeAsyncIterator()
        #expect(await iterator.next() == .signal(SIGTERM))
    }

    // MARK: - API 9

    /// A view tab, a canvas tab and a manifest prompt, and from API 9 a configure panel.
    static func api9Manifest(api: Int = 9) -> String {
        let panels = api >= 9 ? #","panels":[{"id":"setup","title":"Setup","location":"configure"}]"# : ""
        return #"{"id":"io.test.plugin","name":"Test","version":"1","api":\#(api),"entry":"p.js","contributes":{"tabs":[{"id":"v","title":"V","kind":"view"},{"id":"c","title":"C"}]\#(panels),"prompts":[{"name":"linear"}]}}"#
    }

    /// Plugin scope is a store of its own; only a key it actually stored is announced to the other instances.
    @Test func pluginScopedStorageIsSeparateAndAnnouncesWhatItStored() async throws {
        let project = PluginStorage(file: FileManager.default.temporaryDirectory.appending(path: "plugin-storage-\(UUID().uuidString).json"))
        let shared = PluginStorage(file: FileManager.default.temporaryDirectory.appending(path: "plugin-storage-\(UUID().uuidString)"))
        let host = try makeHost([[
            .send(activateOK),
            .send(request(1, "storage/set", #"{"scope":"plugin","key":"k","value":1}"#)),
            .send(request(2, "storage/get", #"{"key":"k"}"#)),
            .send(request(3, "storage/get", #"{"scope":"plugin","key":"k"}"#)),
            .send(request(4, "storage/keys", #"{"scope":"plugin"}"#)),
            .send(request(5, "storage/set", #"{"scope":"team","key":"k","value":1}"#)),
            .send(request(6, "storage/set", #"{"scope":"plugin","key":"","value":1}"#)),
            .send(request(7, "storage/set", #"{"scope":"project","key":"p","value":2}"#)),
        ]], manifest: Self.api9Manifest(), storage: project, pluginStorage: shared)
        var announced: [String] = []
        host.pluginStorageSet = { announced.append($0) }
        await host.activate()
        let sent = replies(host)
        try #require(sent.count == 8)
        #expect(sent[2].contains(#""value":null"#))
        #expect(sent[3].contains(#""value":1"#))
        #expect(sent[4].contains(#"["k"]"#))
        #expect(sent[5].contains(#""code":-32602"#) && sent[5].contains("unknown storage scope"))
        #expect(sent[6].contains(#""code":-32602"#))
        #expect(project.keys() == ["p"] && shared.keys() == ["k"])
        #expect(announced == ["k"])
    }

    @Test(arguments: [
        (9, #"[{"name":"deploy","description":"Ship it"}]"#, nil),
        (9, #"[{"name":"linear"}]"#, -32602),
        (9, #"[{"name":"a"},{"name":"a"}]"#, -32602),
        (9, #"[{"name":"Fix it"}]"#, -32602),
        (9, "[" + (0...32).map { #"{"name":"p\#($0)"}"# }.joined(separator: ",") + "]", -32602),
        (8, #"[{"name":"deploy"}]"#, -32601),
    ] as [(Int, String, Int?)])
    func runtimePromptsAreValidatedAndEndWithTheInstance(api: Int, prompts: String, code: Int?) async throws {
        let host = try makeHost(
            [[.send(activateOK), .send(request(1, "prompts/set", #"{"prompts":\#(prompts)}"#))]], manifest: Self.api9Manifest(api: api))
        await host.activate()
        let reply = try #require(lastReply(host))
        if let code {
            #expect(reply.contains(#""code":\#(code)"#))
            #expect(host.runtimePrompts.isEmpty)
        } else {
            #expect(reply.contains(#""result":{}"#))
            #expect(host.runtimePrompts == [PluginPromptContribution(name: "deploy", description: "Ship it")])
            await host.deactivate()
            #expect(host.runtimePrompts.isEmpty)
        }
    }

    /// Mirrors `panel/visible`: sent when the first view of a tab appears and the last goes, and again to a restarted
    /// instance; API 8 plugins hear nothing.
    @Test(arguments: [9, 8])
    func tabVisibilityIsSentOnTransitionsAndToANewInstance(api: Int) async throws {
        // A configure panel renders with no worktree or run.
        let host = try makeHost(
            [[.send(activateOK)] + (api >= 9 ? [.send(render(panel: "setup"))] : [])], manifest: Self.api9Manifest(api: api))
        func sent() -> [String] {
            host.trace.filter { $0.direction == .toPlugin && $0.text.contains("tab/visible") }.map {
                ($0.text.contains(#""tab":1"#) ? "c" : "v") + ($0.text.contains(#""visible":true"#) ? "+" : "-")
            }
        }
        await host.activate()
        if api >= 9 { #expect(host.panelTree(for: PluginPanelPlace(panel: "setup")) != nil) }
        await host.setTabVisible(0, true)?.value
        await host.setTabVisible(0, true)?.value
        await host.setTabVisible(1, true)?.value
        #expect(host.isTicking)
        await host.setTabVisible(0, false)?.value
        await host.setTabVisible(0, false)?.value
        await host.setTabVisible(9, true)?.value
        #expect(sent() == (api >= 9 ? ["v+", "c+", "v-"] : []))
        await host.deactivate()
        await host.activate()
        #expect(sent() == (api >= 9 ? ["c+"] : []))
    }
}
