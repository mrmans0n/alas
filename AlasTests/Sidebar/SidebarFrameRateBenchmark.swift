import AppKit
import SwiftUI
import Testing
@testable import Alas

/// Frame-rate benchmark for the left sidebar under a typical heavy setup: 15
/// projects (two with seven worktrees, the rest with three, a third with a repo
/// image icon) and three online peers of the same shape and project names, all
/// expanded. Opt-in: it opens a real on-screen
/// window and only runs with `TEST_RUNNER_ALAS_SIDEBAR_BENCH=1` in the
/// `xcodebuild` environment.
///
/// `TEST_RUNNER_ALAS_SIDEBAR_BENCH_ONLY=<substring>` filters scenarios,
/// `..._OUT=<path>` appends the report lines to a file, `..._CLOCK=runloop`
/// paces with a timer for a locked or sleeping display, and
/// `..._TARGET_FPS=90` sets the budget (60 by default).
///
/// The window floats instead of activating, so a run does not take keyboard
/// focus away from whatever you are doing.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ALAS_SIDEBAR_BENCH"] == "1"))
struct SidebarFrameRateBenchmark {
    /// A laptop with a docked terminal below the window, and a large display.
    nonisolated static let heights: [CGFloat] = [480, 900]

    /// A brisk trackpad fling through the whole list and back, twice: the first
    /// pass mounts every row for the first time, the second revisits them.
    @Test(arguments: [CGFloat(240)] + heights)
    func fling(height: CGFloat) async throws {
        try await run("fling h=\(Int(height))", height: height) { bench in
            for pass in 0..<2 {
                await bench.report("pass=\(pass) down", bench.fling(direction: 1))
                await bench.report("pass=\(pass) up", bench.fling(direction: -1))
            }
        }
    }

    /// A sidebar dragged narrow: subtitles stop fitting, so their `ViewThatFits`
    /// measures both alternatives.
    @Test
    func flingNarrow() async throws {
        try await run("narrow h=480", height: 480, width: 220) { bench in
            await bench.report("down", bench.fling(direction: 1))
            await bench.report("up", bench.fling(direction: -1))
        }
    }

    /// The same fling while three peers stream, which is what a session-list
    /// push from a working peer looks like: about three pushes per second.
    @Test(arguments: heights)
    func flingWhilePeersStream(height: CGFloat) async throws {
        try await run("stream h=\(Int(height))", height: height) { bench in
            await bench.report("warmup", bench.fling(direction: 1))
            await bench.report("warmup", bench.fling(direction: -1))
            bench.streamEveryFrames = 30
            await bench.report("down", bench.fling(direction: 1))
            await bench.report("up", bench.fling(direction: -1))
        }
    }

    /// Sitting still while peers stream: what the tree costs per push when
    /// nothing else is going on.
    @Test(arguments: heights)
    func idleWhilePeersStream(height: CGFloat) async throws {
        try await run("idle-stream h=\(Int(height))", height: height) { bench in
            bench.streamEveryFrames = 30
            await bench.report("rest", bench.hold(frames: 360))
        }
    }

    /// Expanding and collapsing peers, the stutter you see at the tap.
    @Test(arguments: heights)
    func togglePeers(height: CGFloat) async throws {
        try await run("toggle h=\(Int(height))", height: height) { bench in
            await bench.report("toggle", bench.togglePeers(everyFrames: 45, toggles: 12))
        }
    }

    /// Collapsing and expanding the last peer while scrolled to its rows at the
    /// bottom of a short window, so the list shrinks past the offset.
    @Test(arguments: [CGFloat(240), 480])
    func togglePeersAtTheBottom(height: CGFloat) async throws {
        try await run("toggle-bottom h=\(Int(height))", height: height) { bench in
            _ = await bench.fling(direction: 1)
            await bench.report("toggle", bench.toggleLastPeer(everyFrames: 45, toggles: 12))
        }
    }

    /// Real phased wheel events through the list, which is the path a trackpad
    /// takes: `setBoundsOrigin` skips the scroll view's gesture handling, and the
    /// momentum phase and landing snap with it.
    @Test(arguments: [CGFloat(240), 480, 900])
    func trackpadSwipes(height: CGFloat) async throws {
        try await run("wheel h=\(Int(height))", height: height) { bench in
            let start = bench.scrollOffset
            await bench.report("swipes", bench.swipes(count: 6))
            #expect(bench.deepestOffset > start + 500, "wheel events never moved the list")
        }
    }

    /// The pointer crossing the peers' section header, which reveals its "+".
    /// Scrolling peers past a resting pointer does this without a mouse move.
    @Test(arguments: heights)
    func hoverPeersHeader(height: CGFloat) async throws {
        try await run("hover h=\(Int(height))", height: height) { bench in
            await bench.report("hover", bench.hoverPeersHeader(everyFrames: 6, frames: 360))
        }
    }

    /// Dragging the window between a small and a large height, which re-lays
    /// out the lazy stack on each frame.
    @Test
    func liveResize() async throws {
        try await run("resize", height: 900) { bench in
            await bench.report("resize", bench.resize(from: 900, to: 360))
        }
    }

    private func run(
        _ name: String,
        height: CGFloat,
        width: CGFloat = 300,
        _ body: (SidebarBenchWindow) async throws -> Void
    ) async throws {
        if let only = ProcessInfo.processInfo.environment["ALAS_SIDEBAR_BENCH_ONLY"], !name.contains(only) { return }
        let bench = try await SidebarBenchWindow(name: name, width: width, height: height)
        defer { bench.close() }
        try await bench.settle()
        try await body(bench)
        print("SIDEBAR-BENCH \(name) doc=\(Int(bench.documentHeight)) views=\(bench.mountedViewCount)")
    }
}

// MARK: - Harness

/// Project shape shared by this Mac and every peer.
private enum SidebarBenchShape {
    static let projects = 15
    static func worktrees(project: Int) -> Int { project < 2 ? 7 : 3 }
    static func name(project: Int) -> String { "Project \(project) with a name" }
    static func hasRepoIcon(project: Int) -> Bool { project % 3 == 0 }
}

@MainActor
private final class SidebarBenchWindow {
    let window: NSWindow
    var streamEveryFrames: Int?

    private let name: String
    private let hosting: NSView
    private let state: AppState
    private let links = SidebarBenchLinks()
    private let client: NativePeerSessions
    private let peerModel = NativePeerSidebarModel()
    private let root: URL
    private var scroller: NSScrollView?
    private var frame = 0
    private var generation = 0
    private var isLive = false
    private var totals: FrameStats?

    private static let peers = [("peer-a", "Studio"), ("peer-b", "Mac mini"), ("peer-c", "Build box")]

    init(name: String, width: CGFloat, height: CGFloat) async throws {
        self.name = name
        root = FileManager.default.temporaryDirectory.appendingPathComponent("alas-sidebar-bench-\(UUID().uuidString)")
        state = AppState(store: SidebarBenchStore(), restoreActiveTabsOnStartup: false)
        for index in 0..<SidebarBenchShape.projects {
            let dir = root.appendingPathComponent("project-\(index)")
            try Self.gitInit(dir)
            if SidebarBenchShape.hasRepoIcon(project: index) { try Self.writeRepoIcon(in: dir, seed: index) }
            let project = try await state.projectsManager.addProject(
                path: dir, displayName: SidebarBenchShape.name(project: index), color: "#6aa0ff"
            )
            state.spacesManager.addProject(project.id, toSpace: state.spacesManager.activeSpaceId)
            for tree in 0..<SidebarBenchShape.worktrees(project: index) {
                state.projectsManager.insertOptimisticWorktree(Worktree(
                    id: "p\(index)-w\(tree)", projectId: project.id, name: "feature/branch-\(index)-\(tree)",
                    branch: "feature/branch-\(index)-\(tree)", path: dir.appendingPathComponent("wt-\(tree)"),
                    isMainWorktree: tree == 0,
                    status: tree % 3 == 1 ? .running : (tree % 2 == 0 ? .dirty : .clean),
                    lastActivity: Date().addingTimeInterval(TimeInterval(-60 * (index * 8 + tree))),
                    addedLines: tree * 13, deletedLines: tree * 5
                ))
            }
        }

        let links = links
        let responder = SidebarBenchResponder()
        let hosts = NativePeerHosts(send: { responder.respond($0, $1) }, supports: { _, _ in true })
        client = NativePeerSessions(
            federation: FederatedSessionsProvider(links: links),
            peers: { links.sessionCarryingPeers.map { .init(serverId: $0.serverId, name: $0.name, state: "online") } },
            hosts: hosts
        )
        responder.respond = { [weak hosts] serverId, message in
            let result: HostResponse? = switch message.request {
            case .snapshot: .snapshot(snapshot: Self.hostSnapshot(serverId: serverId))
            case .subscribeAccepting: .subscribed
            default: nil
            }
            guard let result else { return }
            Task { @MainActor in hosts?.receive(serverId: serverId, .response(id: message.id, result: result)) }
        }
        client.start()
        for (id, peerName) in Self.peers {
            links.online(id, name: peerName)
            links.receive(.projectList(projects: Self.peerProjects(serverId: id)), from: id)
            links.receive(.sessionList(sessions: Self.sessions(serverId: id, generation: 0)), from: id)
        }
        client.refresh()
        state.installNativePeerSessionsForTesting(client)
        peerModel.expandedPeerIDs = Set(Self.peers.map(\.0))
        #expect(client.snapshot.groups.map(\.sessions.isEmpty) == [false, false, false], "peer sessions never arrived")
        try await eventually("peer host snapshots") {
            Self.peers.allSatisfy { hosts.worktrees[$0.0]?.isEmpty == false }
        }

        let theme = try ThemeStore().current
        let view = SidebarView(
            state: state, collapsedProjects: .constant([]),
            onSettings: {}, onAddProject: {}, onAddFolder: {}, onEditProject: { _ in }, onRemoveProject: { _ in },
            onNewWorktree: { _ in }, onCleanupWorktrees: { _ in }, onHideSidebar: {},
            peerSidebarModel: peerModel
        )
        .environment(\.theme, theme)
        let hosting = NSHostingView(rootView: view)
        // The window sets the size. Otherwise the root's fitting size, which the
        // app's split view never asks the sidebar for, dominates a live resize.
        hosting.sizingOptions = []
        self.hosting = hosting
        window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: width, height: height),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = hosting
        window.orderFrontRegardless()
        window.layoutIfNeeded()
    }

    func close() {
        client.stop()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(at: root)
    }

    var documentHeight: CGFloat { scroller?.documentView?.frame.height ?? 0 }

    var mountedViewCount: Int {
        func count(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + count($1) } }
        return count(hosting)
    }

    /// Waits for the lazy stack's content height to stop moving.
    func settle() async throws {
        var last: CGFloat = -1
        var stablePolls = 0
        try await eventually("sidebar to settle") { [self] in
            window.layoutIfNeeded()
            window.displayIfNeeded()
            scroller = Self.largestScroller(in: hosting)
            let height = documentHeight
            stablePolls = height == last && height > 0 ? stablePolls + 1 : 0
            last = height
            return stablePolls >= 10
        }
        guard let scroller else { return }
        // Park the pointer over the list: hover hit-testing is part of a scroll
        // frame, and it is what someone scrolling the sidebar actually pays.
        FrameRateBenchmark.placePointer(over: scroller, in: window)
    }

    func report(_ pass: String, _ stats: FrameStats) {
        stats.report("\(name) \(pass)", label: "SIDEBAR-BENCH", envPrefix: "ALAS_SIDEBAR_BENCH")
        // Frames count against the display's own budget only when asked to.
        if let target = ProcessInfo.processInfo.environment["ALAS_SIDEBAR_BENCH_TARGET_FPS"].flatMap(Double.init) {
            #expect(stats.p95 <= FrameRateBenchmark.budgetMs(fps: target), "\(name) \(pass): p95 \(stats.p95)ms")
        }
    }

    func fling(direction: CGFloat) async -> FrameStats {
        await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_SIDEBAR_BENCH", maxFrames: 4000) { [self] dt in
            guard let scroller else { return false }
            stream()
            // The document height moves as lazy rows get measured; re-read it.
            let maxY = max(0, documentHeight - scroller.contentView.bounds.height)
            let target = min(max(0, scroller.contentView.bounds.origin.y + 2400 * CGFloat(dt) * direction), maxY)
            liveScroll(to: target)
            return direction > 0 ? target < maxY : target > 0
        }
    }

    func hold(frames: Int) async -> FrameStats {
        var remaining = frames
        return await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_SIDEBAR_BENCH", maxFrames: frames) { [self] _ in
            stream()
            remaining -= 1
            return remaining > 0
        }
    }

    var scrollOffset: CGFloat { scroller?.contentView.bounds.origin.y ?? 0 }
    private(set) var deepestOffset: CGFloat = 0

    /// Swipes down then back up: a few frames of gesture, then momentum.
    func swipes(count: Int) async -> FrameStats {
        guard let scroller else { return FrameStats(intervalsMs: []) }
        let pointer = scroller.convert(NSPoint(x: scroller.bounds.midX, y: scroller.bounds.midY), to: nil)
        var script: [(delta: Int32, phase: CGScrollPhase?, momentum: CGMomentumScrollPhase)] = []
        for index in 0..<count {
            let direction: Int32 = index < count / 2 ? -1 : 1
            script.append((direction * 10, .began, .none))
            script += Array(repeating: (direction * 40, .changed, .none), count: 12)
            script.append((0, .ended, .none))
            script.append((direction * 40, nil, .begin))
            script += (0..<50).map { (direction * max(1, 40 - Int32($0)), nil, .continuous) }
            script.append((0, nil, .end))
        }
        var cursor = 0
        return await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_SIDEBAR_BENCH", maxFrames: script.count) { [self] _ in
            stream()
            let step = script[cursor]
            cursor += 1
            Self.sendWheel(delta: step.delta, phase: step.phase, momentum: step.momentum, at: pointer, to: scroller)
            deepestOffset = max(deepestOffset, scrollOffset)
            return cursor < script.count
        }
    }

    private static func sendWheel(
        delta: Int32, phase: CGScrollPhase?, momentum: CGMomentumScrollPhase, at point: NSPoint, to scroller: NSScrollView
    ) {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0
        ) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        guard let window = scroller.window else { return }
        cg.location = CGPoint(
            x: window.frame.minX + point.x,
            y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.minY + point.y)
        )
        guard let event = NSEvent(cgEvent: cg) else { return }
        scroller.scrollWheel(with: event)
    }

    func toggleLastPeer(everyFrames: Int, toggles: Int) async -> FrameStats {
        var ticks = 0
        var remaining = toggles
        let last = Self.peers.map(\.1).sorted().last.flatMap { name in Self.peers.first { $0.1 == name }?.0 } ?? ""
        return await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_SIDEBAR_BENCH", maxFrames: everyFrames * (toggles + 1)) { [self] _ in
            ticks += 1
            if ticks % everyFrames == 0 {
                let repos = client.snapshot.groups.first { $0.id == last }?.repos(ordering: .lastUpdateDesc) ?? []
                peerModel.togglePeer(last, repos: repos)
                remaining -= 1
            }
            return remaining > 0
        }
    }

    func togglePeers(everyFrames: Int, toggles: Int) async -> FrameStats {
        var ticks = 0
        var remaining = toggles
        let all = Set(Self.peers.map(\.0))
        return await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_SIDEBAR_BENCH", maxFrames: everyFrames * (toggles + 1)) { [self] _ in
            ticks += 1
            if ticks % everyFrames == 0 {
                peerModel.expandedPeerIDs = peerModel.expandedPeerIDs.isEmpty ? all : []
                remaining -= 1
            }
            return remaining > 0
        }
    }

    func hoverPeersHeader(everyFrames: Int, frames: Int) async -> FrameStats {
        var ticks = 0
        return await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_SIDEBAR_BENCH", maxFrames: frames) { [self] _ in
            ticks += 1
            if ticks % everyFrames == 0 { peerModel.headerHovering.toggle() }
            return ticks < frames
        }
    }

    func resize(from tall: CGFloat, to short: CGFloat) async -> FrameStats {
        var height = tall
        var step: CGFloat = -8
        var turns = 0
        return await FrameRateBenchmark.drive(on: hosting, envPrefix: "ALAS_SIDEBAR_BENCH", maxFrames: 2000) { [self] _ in
            height += step
            if height <= short || height >= tall {
                step = -step
                turns += 1
            }
            window.setContentSize(NSSize(width: 300, height: height))
            return turns < 4
        }
    }

    /// A push from each peer in turn, as a streaming peer's session list would
    /// arrive: same rows, with the running ones' timestamps and diffs moved.
    private func stream() {
        guard let every = streamEveryFrames else { return }
        frame += 1
        guard frame % every == 0 else { return }
        generation += 1
        let (id, _) = Self.peers[generation % Self.peers.count]
        links.receive(.sessionList(sessions: Self.sessions(serverId: id, generation: generation)), from: id)
    }

    private func liveScroll(to y: CGFloat) {
        guard let scroller else { return }
        if !isLive {
            isLive = true
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroller)
        }
        scroller.contentView.setBoundsOrigin(NSPoint(x: scroller.contentView.bounds.origin.x, y: y))
        scroller.reflectScrolledClipView(scroller.contentView)
    }

    private static func largestScroller(in view: NSView) -> NSScrollView? {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(view).compactMap { $0 as? NSScrollView }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    private static func gitInit(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "-q", dir.path]
        try process.run()
        process.waitUntilExit()
    }

    /// A 512px PNG, the size repos commonly carry as `.alas/icon.png`, with
    /// enough texture to weigh a few hundred KB.
    private static func writeRepoIcon(in dir: URL, seed: Int) throws {
        let side = 512
        var generator = SplitMix64(seed: UInt64(seed + 1))
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try #require(rep.bitmapData)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * rep.bytesPerRow) + x * 4
                let grain = generator.chance(0.05) ? UInt8.random(in: 0...40, using: &generator) : 0
                pixels[offset] = UInt8(x * 255 / side) &+ grain
                pixels[offset + 1] = UInt8(y * 255 / side) &+ grain
                pixels[offset + 2] = UInt8((x + y) * 127 / side) &+ grain
                pixels[offset + 3] = 255
            }
        }
        let alas = dir.appendingPathComponent(".alas", isDirectory: true)
        try FileManager.default.createDirectory(at: alas, withIntermediateDirectories: true)
        try #require(rep.representation(using: .png, properties: [:])).write(to: alas.appendingPathComponent("icon.png"))
    }

    // MARK: Peer fixtures

    private static func peerProjectID(_ project: Int) -> String { "peer-project-\(project)" }

    private static func peerProjects(serverId: String) -> [RemoteProjectOption] {
        (0..<SidebarBenchShape.projects).map { .init(id: peerProjectID($0), name: SidebarBenchShape.name(project: $0)) }
    }

    private static func peerPath(_ serverId: String, _ project: Int, _ tree: Int) -> URL {
        URL(fileURLWithPath: "/srv/\(serverId)/p\(project)/w\(tree)")
    }

    private static func hostSnapshot(serverId: String) -> HostSnapshot {
        var projects: [ProjectSnapshot] = []
        var worktrees: [WorktreeSnapshot] = []
        for project in 0..<SidebarBenchShape.projects {
            projects.append(ProjectSnapshot(ProjectConfig(
                id: peerProjectID(project), name: SidebarBenchShape.name(project: project),
                path: "/srv/\(serverId)/p\(project)", color: "blue", addedAt: .distantPast
            )))
            for tree in 0..<SidebarBenchShape.worktrees(project: project) {
                let path = peerPath(serverId, project, tree)
                worktrees.append(WorktreeSnapshot(
                    worktree: Worktree(
                        id: Worktree.makeId(path: path), projectId: peerProjectID(project),
                        name: "wt-\(tree)", branch: "peer/feature-\(project)-\(tree)", path: path,
                        status: .clean, lastActivity: Date(timeIntervalSince1970: TimeInterval(1_000_000 + project * 10 + tree))
                    ),
                    operation: nil, isArchived: false
                ))
            }
        }
        return HostSnapshot(
            cursor: HostCursor(generation: UUID(), sequence: 0), projects: projects, worktrees: worktrees,
            workspaceCheckouts: [], runs: [], sessions: []
        )
    }

    /// One session on every other worktree; one in three of those is running.
    private static func sessions(serverId: String, generation: Int) -> [RemoteSessionSummary] {
        var rows: [RemoteSessionSummary] = []
        for project in 0..<SidebarBenchShape.projects {
            for tree in 0..<SidebarBenchShape.worktrees(project: project) where (project + tree) % 2 == 0 {
                let streaming = (project + tree) % 3 == 0
                rows.append(.init(
                    id: "s-\(project)-\(tree)", title: "Session \(project)-\(tree)", agentId: "claude",
                    status: streaming ? "streaming" : "idle", canDrive: true, tabIndex: 0,
                    projectId: peerProjectID(project),
                    worktreeId: Worktree.makeId(path: peerPath(serverId, project, tree)),
                    updatedAt: Int64(1_000 + (streaming ? generation : 0) + project * 10 + tree),
                    worktree: .init(
                        projectName: SidebarBenchShape.name(project: project), worktreeName: "wt-\(tree)",
                        branch: "peer/feature-\(project)-\(tree)", path: peerPath(serverId, project, tree).path,
                        metricsAvailable: true, comparisonRef: "origin/main", commitCount: tree,
                        changedFileCount: tree, addedLines: 10 * tree + (streaming ? generation : 0),
                        deletedLines: 3 * tree, conflictCount: 0, isMain: tree == 0
                    )
                ))
            }
        }
        return rows
    }
}

/// Answers host requests, once the channel it answers through exists.
@MainActor
private final class SidebarBenchResponder {
    var respond: (String, HostClientMessage) -> Void = { _, _ in }
}

private struct SidebarBenchStore: PersistenceStoreProtocol {
    func write<T: Encodable>(_: T, to _: URL) throws {}
    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
}

private final class SidebarBenchLinks: FederatedPeerLinks {
    var sessionCarryingPeers: [FederatedPeerInfo] = []
    var onFederationEvent: (@MainActor (FederatedPeerLinkEvent) -> Void)?

    func sendToPeer(_ message: RemoteClientMessage, serverId: String) {}
    func peerSupports(_ capability: String, serverId: String) -> Bool { true }

    func online(_ id: String, name: String) {
        sessionCarryingPeers.append(.init(serverId: id, name: name))
        onFederationEvent?(.availabilityChanged(serverId: id))
    }

    func receive(_ message: RemoteServerMessage, from id: String) {
        onFederationEvent?(.message(serverId: id, message))
    }
}
