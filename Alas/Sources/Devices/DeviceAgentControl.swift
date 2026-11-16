import AlasCore
import Foundation
import IOSurface
import Observation

/// What the device controller needs from the simulator service.
/// `SimulatorStreamClient` is the real one.
@MainActor
protocol DeviceInput: AnyObject {
    func subscribe(
        udid: String,
        onFrame: @escaping @MainActor (DeviceFrame) -> Void,
        onStop: @escaping @MainActor (String) -> Void
    ) -> UUID
    func unsubscribe(udid: String, token: UUID)
    func touch(udid: String, phase: String, point: DeviceScreenPoint)
    func key(udid: String, usage: UInt32, down: Bool)
    func button(udid: String, name: String)
    func describe(udid: String) async throws -> Data
    func lastFrame(udid: String) -> DeviceFrame?
    func rotate(udid: String, to orientation: DeviceScreenOrientation) async throws
}

extension SimulatorStreamClient: DeviceInput {}

/// Runs the `device_*` tools for agents on simulators and Android devices,
/// through one backend per platform, and tracks who drives each device so
/// the Devices tab can show it and the user can take over.
@MainActor
@Observable
final class DeviceAgentControl {
    static let disabled =
        "device_disabled: Agents can't use simulators or Android devices. Ask the user to turn on Settings › Computer Use › Let agents use simulators and Android devices."
    static let userDriving = "device_user_active: The user took over this simulator. Try again after they hand it back."
    static let stillDriving = "device_user_active: The user is still driving this simulator. Try again in a minute."
    /// The session of a flow the user runs from the toolbar.
    static let userFlowSession = "flow:user"
    /// The agent cancelled the call, or its MCP server went away.
    static let cancelled = "device_cancelled: The call was cancelled."

    private struct AgentCall {
        let sessionID: String
        let tool: String
        let at: Date
    }

    @ObservationIgnored private let backends: [any DeviceBackend]
    @ObservationIgnored private let recorder: DeviceRecorder
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private let leaseWindow: Duration
    /// How long a call waits for the user to hand a simulator back; under
    /// Codex's 60-second limit on a tool call.
    /// Calls waiting for the user to hand a simulator back.
    @ObservationIgnored private let holds: HeldCalls

    /// A released call carries its input turn when it needs one.
    private enum Hold: Sendable { case go(inputTurn: UUID?), timedOut, cancelled }

    private var lastCalls: [String: AgentCall] = [:]
    private var inFlight: [String: Int] = [:]
    private var takenOver: Set<String> = []
    @ObservationIgnored private var snapshots: [String: DeviceSnapshot] = [:]
    /// The session that last received each device's screen: diffs are against
    /// what the calling session saw, not another session's view.
    @ObservationIgnored private var snapshotSessions: [String: String] = [:]
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var screenshotSizes: [String: (width: Double, height: Double)] = [:]
    @ObservationIgnored private var leases: [String: (token: UUID, release: Task<Void, Never>)] = [:]
    /// Each device's input turns, in the order they were taken; the first runs.
    @ObservationIgnored private var inputTurns: [String: [UUID]] = [:]
    /// Calls waiting for their turn to come up.
    @ObservationIgnored private var inputWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// The backend each device was last found in, for the paths that don't list devices.
    @ObservationIgnored private var routes: [String: AgentDevice.Platform] = [:]
    /// Flows agent sessions are recording, by device.
    @ObservationIgnored private var flowRecordings: [String: FlowRecording] = [:]

    /// A flow running on a device, for the stage.
    struct FlowProgress: Equatable {
        let name: String
        let step: Int
        let total: Int
    }

    /// The flow running on each device.
    private(set) var flowRuns: [String: FlowProgress] = [:]

    private struct FlowRecording {
        let sessionID: String
        let path: String
        var flow = DeviceFlow(appID: nil, steps: [])

        /// The first app launched becomes the flow's `appId`.
        mutating func add(_ step: DeviceFlow.Step) {
            guard case .launchApp(let id?) = step else { return flow.steps.append(step) }
            if flow.appID == nil { flow.appID = id }
            flow.steps.append(.launchApp(id == flow.appID ? nil : id))
        }
    }

    init(
        backends: [any DeviceBackend],
        recorder: DeviceRecorder,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        leaseWindow: Duration = .seconds(60),
        holdLimit: Duration = .seconds(50)
    ) {
        self.backends = backends
        self.recorder = recorder
        self.now = now
        self.sleep = sleep
        self.leaseWindow = leaseWindow
        holds = HeldCalls(limit: holdLimit, sleep: sleep)
    }

    // MARK: Driver

    func driver(udid: String, at date: Date? = nil) -> VMDriver {
        VMDriver.current(
            lastAgentCall: lastCalls[udid].map { ($0.sessionID, $0.tool, $0.at) },
            inFlight: (inFlight[udid] ?? 0) > 0,
            takenOver: takenOver.contains(udid),
            now: date ?? now()
        )
    }

    func takeOver(udid: String) {
        takenOver.insert(udid)
    }

    func handBack(udid: String) {
        takenOver.remove(udid)
        holds.releaseAll(udid)
    }

    /// Sessions whose calls wait for the user to hand `udid` back, first to arrive first.
    func waitingSessions(udid: String) -> [String] {
        holds.waiting(udid)
    }

    /// Waits while the user drives `udid`: until they hand it back, the hold
    /// limit passes, or the calling task is cancelled.
    private func holdWhileTakenOver(_ udid: String, sessionID: String, isInput: Bool) async -> Hold {
        guard takenOver.contains(udid) else { return .go(inputTurn: nil) }
        guard !Task.isCancelled else { return .cancelled }
        // Input turns are taken at release, in arrival order: a released call still
        // lists devices before it runs, and those listings can finish in any order.
        var turn: UUID?
        let outcome = await holds.hold(udid, sessionID: sessionID) { [weak self] in
            if isInput { turn = self?.takeInputTurn(udid) }
        }
        switch outcome {
        case .released: return .go(inputTurn: turn)
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        }
    }

    private func userDriving(_ udid: String) -> Bool {
        VMDriver.decision(for: driver(udid: udid)) == .userDriving
    }

    // MARK: Calls

    func perform(_ command: DeviceCommand, sessionID: String) async -> AlasCLIResponse {
        guard let udid = command.udid else { return await list() }
        // A read the user's driving doesn't disturb: neither held nor queued.
        if case .logs(_, let since, let bundleID, let level, let includeApple, let query, let limit) = command {
            return await readLogs(
                udid: udid, since: since, bundleID: bundleID, level: level, includeApple: includeApple, query: query, limit: limit
            )
        }
        // Recording doesn't touch the screen, so it works while the user drives.
        if case .record(_, let start) = command {
            return await record(udid: udid, start: start, sessionID: sessionID)
        }
        // Recording a flow doesn't touch the screen either.
        if case .recordFlow(_, let path) = command {
            return await recordFlow(udid: udid, path: path, sessionID: sessionID)
        }
        if case .clipboard(_, nil) = command {
            switch await bootedDevice(udid) {
            case .failure(let refusal): return refusal.response
            case .success(let found):
                do { return .text([Self.json(["text": try await found.backend.readClipboard(udid)])]) } catch {
                    return .error("device_clipboard_failed: \(error.localizedDescription)")
                }
            }
        }
        // Touches and keys from two calls must not interleave on one simulator,
        // so input calls to a device run one at a time, in arrival order;
        // installing and launching take their turn too.
        let isInput = switch command {
        case .tap, .swipe, .type, .button, .install, .launch,
             .setAppearance, .setAccessibility, .setPermission, .setLocation, .push, .openURL, .clipboard, .rotate,
             .setNetwork, .clearData, .runFlow, .setRoute: true
        case .list, .open, .snapshot, .screenshot, .logs, .record, .recordFlow: false
        }
        var inputTurn: UUID?
        switch await holdWhileTakenOver(udid, sessionID: sessionID, isInput: isInput) {
        case .go(let turn): inputTurn = turn
        case .timedOut: return .error(Self.stillDriving)
        case .cancelled: return .error(Self.cancelled)
        }
        // Taken before the device listing below, whose calls can finish in any order.
        if isInput, inputTurn == nil { inputTurn = takeInputTurn(udid) }
        defer { if let inputTurn { endInputTurn(udid, inputTurn) } }
        let backend: any DeviceBackend
        var device: AgentDevice
        // device_open of an AVD that already runs answers with its emulator.
        let byAlias = if case .open = command { true } else { false }
        switch await locate(udid, acceptingAlias: byAlias) {
        case .failure(let refusal): return refusal.response
        case .success(let found): (backend, device) = (found.backend, found.device)
        }
        // Who drives is tracked under the device's own id: an AVD's `avd:` id
        // names it until it boots, then its emulator's serial does.
        var driven = device.id
        if userDriving(driven) { return .error(Self.userDriving) }

        lastCalls[driven] = AgentCall(sessionID: sessionID, tool: command.toolName, at: now())
        inFlight[driven, default: 0] += 1
        var leased: String?
        defer {
            inFlight[driven, default: 1] -= 1
            lastCalls[driven] = AgentCall(sessionID: sessionID, tool: command.toolName, at: now())
            // The idle window starts when the call ends, not when it began.
            if let leased { renewLease(leased) }
        }

        if case .open = command, !device.isBooted {
            do {
                // An AVD comes back as its emulator, under a new id.
                let id = try await backend.boot(udid)
                device = (try? await backend.devices().first { $0.id == id })
                    ?? AgentDevice(id: id, name: device.name, platform: device.platform, runtime: device.runtime, state: "booted")
                routes[id] = backend.platform
                if id != driven {
                    inFlight[driven, default: 1] -= 1
                    lastCalls[driven] = nil
                    driven = id
                    inFlight[driven, default: 0] += 1
                    lastCalls[driven] = AgentCall(sessionID: sessionID, tool: command.toolName, at: now())
                }
            } catch let error as DeviceToolError {
                return .error(error.message)
            } catch {
                return .error("device_not_booted: \(error.localizedDescription)")
            }
        }
        if let refusal = Self.notReady(device) { return refusal.response }
        // The device's own id: after device_open of an AVD, its emulator's.
        renewLease(device.id)
        leased = device.id
        let needsStream = switch command {
        case .tap, .swipe, .type, .button, .screenshot, .rotate, .clipboard, .runFlow: true
        default: false
        }
        if needsStream, await !backend.ready(device.id) {
            return .error("device_unavailable: The screen of \(device.name) didn't start. Try again in a moment.")
        }

        if let inputTurn {
            await waitForInputTurn(udid, inputTurn)
            if Task.isCancelled { return .error(Self.cancelled) }
            if userDriving(udid) { return .error(Self.userDriving) }
        }

        // Named from the screen before the call: a tap's element may be gone after it.
        let step = flowRecordings[udid]?.sessionID == sessionID ? flowStep(for: command, udid: udid) : nil
        let response = await dispatch(command, udid: udid, backend: backend, device: device, sessionID: sessionID)
        let failed = if case .error = response { true } else { false }
        if let step, !failed, flowRecordings[udid]?.sessionID == sessionID { flowRecordings[udid]?.add(step) }
        return response
    }

    private func dispatch(
        _ command: DeviceCommand, udid: String, backend: any DeviceBackend, device: AgentDevice, sessionID: String
    ) async -> AlasCLIResponse {
        switch command {
        case .list:
            return await list()
        case .open:
            return .text([Self.json(device.json)])
        case .snapshot(_, let query, let limit):
            do {
                let snapshot = try await takeSnapshot(udid)
                // One that finishes after a newer snapshot doesn't replace it.
                if (snapshots[udid]?.generation ?? 0) < snapshot.generation {
                    snapshots[udid] = snapshot
                    // Only a whole screen is a baseline: a filtered one left elements out.
                    let whole = (query ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                        && !snapshot.filtered(query: query, limit: limit).truncated
                    snapshotSessions[udid] = whole ? sessionID : nil
                }
                return .text([snapshot.json(query: query, limit: limit)])
            } catch {
                return .error(Self.snapshotError(error))
            }
        case .screenshot:
            return await screenshot(udid)
        case .tap(_, let target, let includeScreenshot, let diff):
            let point: DeviceScreenPoint
            switch resolve(target, udid: udid) {
            case .success(let resolved): point = resolved
            case .failure(let failure): return .error(failure.message)
            }
            backend.input.touch(udid: udid, phase: "begin", point: point)
            await sleep(.milliseconds(50))
            backend.input.touch(udid: udid, phase: "end", point: point)
            return await finish(udid, includeScreenshot: includeScreenshot, diff: diff, sessionID: sessionID)
        case .swipe(_, let gesture, let durationMs, let includeScreenshot, let diff):
            let from: DeviceScreenPoint
            let to: DeviceScreenPoint
            switch swipeEnds(gesture, udid: udid) {
            case .success(let ends): (from, to) = ends
            case .failure(let failure): return .error(failure.message)
            }
            if let stopped = await drag(udid, backend: backend, from: from, to: to, durationMs: durationMs) { return stopped }
            return await finish(udid, includeScreenshot: includeScreenshot, diff: diff, sessionID: sessionID)
        case .type(_, let text, let includeScreenshot, let diff):
            let runs = DeviceTextInput.runs(for: text)
            let total = runs.reduce(0) { $0 + $1.characterCount }
            var paste: (any DevicePasteSession)?
            let stopped = await typeRuns(runs, total: total, udid: udid, backend: backend, paste: &paste)
            if let paste { await paste.end() }
            if let stopped { return stopped }
            return await finish(udid, includeScreenshot: includeScreenshot, diff: diff, sessionID: sessionID)
        case .button(_, let name, let includeScreenshot, let diff):
            guard backend.press(udid, name) else {
                return .error("device_unsupported: The \(name.rawValue) button isn't available on \(device.platform.rawValue).")
            }
            return await finish(udid, includeScreenshot: includeScreenshot, diff: diff, sessionID: sessionID)
        case .install(_, let appPath):
            do {
                let app = try await backend.install(udid, path: appPath)
                return .text([Self.json(["bundle_id": app.appID, "name": app.name])])
            } catch let error as DeviceToolError {
                return .error(error.message)
            } catch {
                return .error("device_install_failed: \(error.localizedDescription)")
            }
        case .launch(_, let bundleID, let diff):
            do {
                let pid = try await backend.launch(udid, appID: bundleID)
                return .text([Self.json(await withDiff(["pid": pid], udid: udid, diff: diff, sessionID: sessionID))])
            } catch is DeviceAppNotInstalled {
                return Self.notInstalled(bundleID, on: device)
            } catch let error as DeviceToolError {
                return .error(error.message)
            } catch {
                return .error("device_launch_failed: \(error.localizedDescription)")
            }
        case .setAppearance(_, let appearance, let textSize, let increaseContrast):
            return await settingsCall {
                .text([Self.json(try await backend.setDisplay(
                    udid, appearance: appearance, textSize: textSize, increaseContrast: increaseContrast
                ).json)])
            }
        case .setAccessibility(_, let change):
            return await settingsCall {
                .text([Self.json(try await backend.setAccessibility(udid, change).json)])
            }
        case .setNetwork(_, let wifi, let data):
            return await settingsCall {
                .text([Self.json(try await backend.setNetwork(udid, wifi: wifi, data: data).json)])
            }
        case .clearData(_, let bundleID):
            guard await backend.isInstalled(udid, appID: bundleID) else { return Self.notInstalled(bundleID, on: device) }
            return await settingsCall {
                try await backend.clearData(udid, appID: bundleID)
                return .text([Self.json(["ok": true])])
            }
        case .setPermission(_, let bundleID, let service, let action):
            guard await backend.isInstalled(udid, appID: bundleID) else { return Self.notInstalled(bundleID, on: device) }
            return await settingsCall {
                try await backend.setPermission(udid, appID: bundleID, service: service, action: action)
                return .text([Self.json(["ok": true])])
            }
        case .setLocation(_, let location):
            return await settingsCall {
                try await backend.setLocation(udid, location)
                return .text([Self.json(["ok": true])])
            }
        case .push(_, let bundleID, let payload):
            guard await backend.isInstalled(udid, appID: bundleID) else { return Self.notInstalled(bundleID, on: device) }
            return await settingsCall {
                try await backend.push(udid, appID: bundleID, payload: Data(payload.utf8))
                return .text([Self.json(["ok": true])])
            }
        case .openURL(_, let url, let diff):
            do {
                try await backend.openURL(udid, url)
            } catch let error as DeviceToolError {
                return .error(error.message)
            } catch {
                return .error("device_settings_failed: \(error.localizedDescription)")
            }
            return .text([Self.json(await withDiff(["ok": true], udid: udid, diff: diff, sessionID: sessionID))])
        case .clipboard(_, let text):
            do {
                try await backend.writeClipboard(udid, text ?? "")
                return .text([Self.json(["ok": true])])
            } catch {
                return .error("device_clipboard_failed: \(error.localizedDescription)")
            }
        case .rotate(_, let orientation, let diff):
            return await rotate(udid, backend: backend, to: orientation, diff: diff, sessionID: sessionID)
        case .runFlow(_, let path):
            return await runFlow(path: path, udid: udid, backend: backend, device: device)
        case .setRoute(_, let waypoints, let gpxPath, let speedKmh):
            let route: DeviceRoute
            do {
                if let gpxPath {
                    let name = URL(fileURLWithPath: gpxPath).deletingPathExtension().lastPathComponent
                    route = try DeviceRoute.gpx(String(contentsOfFile: gpxPath, encoding: .utf8), name: name, speedKmh: speedKmh)
                } else {
                    route = DeviceRoute(name: "Route", points: waypoints ?? [], speed: speedKmh / 3.6)
                }
            } catch {
                return .error("device_route_invalid: \(error.localizedDescription)")
            }
            return await settingsCall {
                try await backend.startRoute(udid, route)
                return .text([Self.json([
                    "points": route.points.count,
                    // A decimal, so the JSON says 0.11 and not 0.10999999.
                    "km": NSDecimalNumber(string: String(format: "%.2f", route.length / 1000)),
                    "seconds": Int(route.duration.rounded()),
                ])])
            }
        case .logs, .record, .recordFlow:
            // Answered before the hold.
            return .error("device_unavailable: The call took the wrong path.")
        }
    }

    /// A touch dragged from one panel point to another; the response that stopped it, or nil.
    private func drag(
        _ udid: String, backend: any DeviceBackend, from: DeviceScreenPoint, to: DeviceScreenPoint, durationMs: Int
    ) async -> AlasCLIResponse? {
        let steps = max(1, durationMs / 16)
        var current = from
        backend.input.touch(udid: udid, phase: "begin", point: from)
        for step in 1...steps {
            await sleep(.milliseconds(16))
            if userDriving(udid) || Task.isCancelled {
                backend.input.touch(udid: udid, phase: "end", point: current)
                return .error(Task.isCancelled ? Self.cancelled : Self.userDriving)
            }
            let fraction = Double(step) / Double(steps)
            current = DeviceScreenPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
            backend.input.touch(udid: udid, phase: step == steps ? "end" : "move", point: current)
        }
        return nil
    }

    // MARK: Flows

    /// Runs a flow file's steps through the same paths as the tools, as one
    /// call: it stops at the first step that fails and says which.
    private func runFlow(path: String, udid: String, backend: any DeviceBackend, device: AgentDevice) async -> AlasCLIResponse {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let flow: DeviceFlow
        do {
            flow = try DeviceFlow.parse(String(contentsOfFile: path, encoding: .utf8))
        } catch let error as DeviceFlowError {
            return .error("device_flow_invalid: \(name), line \(error.line): \(error.message)")
        } catch {
            return .error("device_flow_not_found: \(error.localizedDescription)")
        }
        defer { flowRuns[udid] = nil }
        for (index, step) in flow.steps.enumerated() {
            flowRuns[udid] = FlowProgress(name: name, step: index + 1, total: flow.steps.count)
            let reason: String?
            if Task.isCancelled {
                reason = "The call was cancelled."
            } else if userDriving(udid) {
                reason = "The user took over."
            } else {
                reason = await runStep(step, appID: flow.appID, udid: udid, backend: backend, device: device)
            }
            if let reason {
                return .text([Self.json([
                    "passed": false, "failed_step": index + 1, "line": flow.lines[index], "reason": reason,
                    "steps": flow.steps.count,
                ])])
            }
        }
        return .text([Self.json(["passed": true, "steps": flow.steps.count])])
    }

    /// Why a step failed, or nil when it passed.
    private func runStep(
        _ step: DeviceFlow.Step, appID: String?, udid: String, backend: any DeviceBackend, device: AgentDevice
    ) async -> String? {
        switch step {
        case .launchApp(let id):
            guard let app = id ?? appID else { return "launchApp needs an appId in the flow's header." }
            do {
                _ = try await backend.launch(udid, appID: app)
            } catch is DeviceAppNotInstalled {
                return "\(app) isn't installed on \(device.name)."
            } catch let error as DeviceToolError {
                return error.message
            } catch {
                return error.localizedDescription
            }
        case .tapOn(let selector):
            let upright: DeviceScreenPoint
            if case .point(let x, let y) = selector {
                upright = DeviceScreenPoint(x: x, y: y)
            } else {
                switch await waitFor(selector, udid: udid, visible: true) {
                case .failure(let failure): return failure.message
                case .success(let found):
                    guard let found else { return "No element to tap." }
                    upright = found.snapshot.center(of: found.element)
                }
            }
            let point = panelPoint(upright, udid: udid)
            backend.input.touch(udid: udid, phase: "begin", point: point)
            await sleep(.milliseconds(50))
            backend.input.touch(udid: udid, phase: "end", point: point)
        case .inputText(let text):
            let runs = DeviceTextInput.runs(for: text)
            var paste: (any DevicePasteSession)?
            let stopped = await typeRuns(
                runs, total: runs.reduce(0) { $0 + $1.characterCount }, udid: udid, backend: backend, paste: &paste
            )
            if let paste { await paste.end() }
            if case .error(let message)? = stopped { return message }
        case .eraseText(let count):
            // Delete (Backspace).
            for _ in 0..<count {
                if Task.isCancelled { return "The call was cancelled." }
                if userDriving(udid) { return "The user took over." }
                backend.input.key(udid: udid, usage: 0x2A, down: true)
                backend.input.key(udid: udid, usage: 0x2A, down: false)
                await sleep(.milliseconds(20))
            }
        case .pressKey(.enter):
            backend.input.key(udid: udid, usage: 0x28, down: true)
            backend.input.key(udid: udid, usage: 0x28, down: false)
        case .pressKey(let key):
            guard backend.press(udid, key == .home ? .home : .back) else {
                return "The \(key.rawValue) key isn't available on \(device.platform == .ios ? "iOS" : "Android")."
            }
        case .scroll, .swipe:
            let direction: DeviceCommand.Direction = if case .swipe(let way) = step {
                DeviceCommand.Direction(rawValue: way.rawValue.lowercased()) ?? .up
            } else {
                .up
            }
            guard case .success(let ends) = swipeEnds(.direction(direction), udid: udid) else { return "The swipe failed." }
            if case .error(let message)? = await drag(udid, backend: backend, from: ends.0, to: ends.1, durationMs: 300) {
                return message
            }
        case .assertVisible(let selector), .assertNotVisible(let selector):
            let visible = if case .assertVisible = step { true } else { false }
            if case .failure(let failure) = await waitFor(selector, udid: udid, visible: visible) { return failure.message }
            return nil
        case .openLink(let url):
            do {
                try await backend.openURL(udid, url)
            } catch let error as DeviceToolError {
                return error.message
            } catch {
                return error.localizedDescription
            }
        case .waitForAnimationToEnd:
            break
        }
        _ = await settle(udid)
        return nil
    }

    /// Polls snapshots every 250 ms until the selector's element is there
    /// (`visible`) or gone, for up to 5 s by the clock: an Android snapshot alone
    /// takes about 2 s. At most 20 polls, so tests with instant clocks end.
    private func waitFor(
        _ selector: DeviceFlow.Selector, udid: String, visible: Bool
    ) async -> Result<(snapshot: DeviceSnapshot, element: DeviceElement)?, Failure> {
        let described: String
        switch selector {
        case .text(let text): described = "text \"\(text)\""
        case .id(let id): described = "id \"\(id)\""
        case .point: return .failure(Failure(message: "Assertions take text or an id, not a point."))
        }
        var snapshotFailure: String?
        let started = now()
        for attempt in 0..<20 {
            if attempt > 0 {
                if now().timeIntervalSince(started) >= 5 { break }
                await sleep(.milliseconds(250))
            }
            if Task.isCancelled { return .failure(Failure(message: "The call was cancelled.")) }
            if userDriving(udid) { return .failure(Failure(message: "The user took over.")) }
            do {
                let snapshot = try await takeSnapshot(udid)
                snapshotFailure = nil
                // The user can take over while a snapshot is read (about 2 s on Android).
                if Task.isCancelled { return .failure(Failure(message: "The call was cancelled.")) }
                if userDriving(udid) { return .failure(Failure(message: "The user took over.")) }
                switch (DeviceFlow.find(selector, in: snapshot), visible) {
                case (let element?, true): return .success((snapshot, element))
                case (nil, false): return .success(nil)
                default: continue
                }
            } catch {
                snapshotFailure = Self.snapshotError(error)
            }
        }
        if let snapshotFailure { return .failure(Failure(message: snapshotFailure)) }
        if visible { return .failure(Failure(message: "No element with \(described) after 5 s.")) }
        let what = if case .text(let text) = selector { "\"\(text)\"" } else { "The element with \(described)" }
        return .failure(Failure(message: "\(what) is still visible after 5 s."))
    }

    /// A call as a flow step, or nil for calls a flow has no step for.
    private func flowStep(for command: DeviceCommand, udid: String) -> DeviceFlow.Step? {
        switch command {
        case .tap(_, .ref(let ref), _, _):
            guard let snapshot = snapshots[udid], let element = snapshot.element(ref: ref) else { return nil }
            return .tapOn(DeviceFlow.selector(for: element, at: snapshot.center(of: element)))
        case .tap(_, .point(let x, let y), _, _):
            guard case .success(let point) = screenPoint(x: x, y: y, udid: udid) else { return nil }
            return .tapOn(DeviceFlow.selector(for: snapshots[udid].flatMap { DeviceFlow.element(at: point, in: $0) }, at: point))
        case .swipe(_, .direction(let direction), _, _, _):
            return DeviceFlow.Direction(rawValue: direction.rawValue.uppercased()).map { .swipe($0) }
        case .swipe(_, .points(let fromX, let fromY, let toX, let toY), _, _, _):
            let (dx, dy) = (toX - fromX, toY - fromY)
            return .swipe(abs(dx) > abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down))
        case .type(_, let text, _, _): return .inputText(text)
        case .button(_, .home, _, _): return .pressKey(.home)
        case .button(_, .back, _, _): return .pressKey(.back)
        case .launch(_, let bundleID, _): return .launchApp(bundleID)
        case .openURL(_, let url, _): return .openLink(url)
        default: return nil
        }
    }

    /// A path starts recording this session's calls on the device; nil stops and writes the flow.
    private func recordFlow(udid: String, path: String?, sessionID: String) async -> AlasCLIResponse {
        if let path {
            let device: AgentDevice
            switch await bootedDevice(udid) {
            case .failure(let refusal): return refusal.response
            case .success(let found): device = found.device
            }
            if let current = flowRecordings[udid] {
                let who = current.sessionID == sessionID ? "This session" : "Another agent session"
                return .error("device_recording_busy: \(who) is already recording a flow on \(device.name).")
            }
            flowRecordings[udid] = FlowRecording(sessionID: sessionID, path: path)
            return .text([Self.json(["recording": true])])
        }
        let name = (try? await locate(udid).get().device.name) ?? udid
        guard let recording = flowRecordings[udid], recording.sessionID == sessionID else {
            return .error("device_not_recording: No flow is being recorded on \(name) by this session.")
        }
        do {
            let file = URL(fileURLWithPath: recording.path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try recording.flow.yaml.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            // Kept, so a stop after fixing the folder still saves it.
            return .error("device_flow_record_failed: \(error.localizedDescription) The recording is kept; call stop again to retry.")
        }
        flowRecordings[udid] = nil
        return .text([Self.json(["path": recording.path, "steps": recording.flow.steps.count])])
    }

    private func rotate(
        _ udid: String, backend: any DeviceBackend, to orientation: DeviceScreenOrientation, diff: Bool, sessionID: String
    ) async -> AlasCLIResponse {
        let interface: DeviceScreenOrientation
        do {
            interface = try await backend.rotate(udid, to: orientation)
        } catch {
            return .error("device_rotate_failed: \(error.localizedDescription)")
        }
        let reply: [String: Any] = ["device": orientation.rawValue, "interface": interface.rawValue]
        return .text([Self.json(await withDiff(reply, udid: udid, diff: diff, sessionID: sessionID))])
    }

    private func record(udid: String, start: Bool, sessionID: String) async -> AlasCLIResponse {
        let device: AgentDevice
        if start {
            switch await bootedDevice(udid) {
            case .failure(let refusal): return refusal.response
            case .success(let found): device = found.device
            }
        } else {
            // A recording that ended at shutdown is still collected.
            let listed = try? await locate(udid).get().device
            device = listed ?? AgentDevice(id: udid, name: udid, platform: .ios, runtime: "", state: "shutdown")
        }
        let owner = DeviceRecorder.Owner.agent(sessionID: sessionID)
        do throws(DeviceRecorder.Failure) {
            if start {
                try recorder.start(udid: udid, owner: owner, file: DeviceRecorder.agentFile(udid: udid, now: now()))
                return .text([Self.json(["recording": true])])
            }
            let finished = try await recorder.stop(udid: udid, owner: owner)
            // A decimal, so the JSON says 3.3 and not 3.2999999999999998.
            let seconds = NSDecimalNumber(string: String(format: "%.1f", finished.seconds))
            return .text([Self.json(["path": finished.file.path, "seconds": seconds])])
        } catch {
            switch error {
            case .busy(let other):
                let who = other == .user ? "The user" : "Another agent session"
                return .error("device_recording_busy: \(who) is recording \(device.name).")
            case .notRecording:
                return .error("device_not_recording: No recording of \(device.name) by this session is running.")
            case .failed(let reason):
                return .error("device_record_failed: \(reason)")
            case .notSaved(let file, let reason):
                // Agents' recordings aren't moved; kept for completeness.
                return .error("device_record_failed: \(reason) The video is at \(file.path).")
            }
        }
    }

    /// Why a call can't use a simulator.
    private struct Refusal: Error {
        let response: AlasCLIResponse
    }

    /// Finds `udid` in the backend its shape suggests first (a UUID is a
    /// simulator), then the others, and remembers where it was. A device found
    /// by its alias is refused unless `acceptingAlias`.
    private func locate(
        _ udid: String, acceptingAlias: Bool = false
    ) async -> Result<(backend: any DeviceBackend, device: AgentDevice), Refusal> {
        let preferred: AgentDevice.Platform = AgentDevice.isSimulatorID(udid) ? .ios : .android
        let ordered = backends.filter { $0.platform == preferred } + backends.filter { $0.platform != preferred }
        var failure: (any Error)?
        for backend in ordered {
            do {
                if let device = try await backend.devices().first(where: { $0.id == udid || $0.alias == udid }) {
                    if device.id != udid, !acceptingAlias {
                        return .failure(Refusal(response: .error(
                            "device_not_found: \(udid) is running as \(device.id); use that udid."
                        )))
                    }
                    routes[device.id] = backend.platform
                    return .success((backend, device))
                }
            } catch {
                failure = failure ?? error
            }
        }
        // A backend that couldn't list may hold the device: say why rather than "not found".
        if let failure {
            return .failure(Refusal(response: .error("device_unavailable: \(failure.localizedDescription)")))
        }
        return .failure(Refusal(response: .error("device_not_found: No device \(udid). Call device_list.")))
    }

    private func bootedDevice(_ udid: String) async -> Result<(backend: any DeviceBackend, device: AgentDevice), Refusal> {
        switch await locate(udid) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found):
            if let refusal = Self.notReady(found.device) { return .failure(refusal) }
            return .success(found)
        }
    }

    /// Why a device can't take a call yet, or nil when it is booted.
    private static func notReady(_ device: AgentDevice) -> Refusal? {
        switch device.state {
        case "booted": nil
        case "shutdown", "shutting_down":
            Refusal(response: .error("device_not_booted: \(device.name) is shut down. Call device_open to boot it."))
        case "unauthorized":
            Refusal(response: .error("device_not_ready: \(device.name) hasn't allowed USB debugging; ask the user to allow it on the phone."))
        default:
            Refusal(response: .error("device_not_ready: \(device.name) is \(device.state)."))
        }
    }

    /// Types key runs and pastes the rest, opening the paste on the first
    /// paste run. Returns the response that stopped it, or nil when all of it went in.
    private func typeRuns(
        _ runs: [DeviceTextInput.Run], total: Int, udid: String, backend: any DeviceBackend,
        paste: inout (any DevicePasteSession)?
    ) async -> AlasCLIResponse? {
        let shift: UInt32 = 0xE1
        var typed = 0
        func stop() -> AlasCLIResponse? {
            if Task.isCancelled {
                return .error("device_cancelled: The call was cancelled after \(typed) of \(total) characters were typed.")
            }
            if userDriving(udid) {
                return .error("device_user_active: The user took over after \(typed) of \(total) characters were typed. Check the field before typing the rest.")
            }
            return nil
        }
        for run in runs {
            switch run {
            case .keys(let presses):
                for press in presses {
                    if let stopped = stop() { return stopped }
                    if press.shift { backend.input.key(udid: udid, usage: shift, down: true) }
                    backend.input.key(udid: udid, usage: press.usage, down: true)
                    backend.input.key(udid: udid, usage: press.usage, down: false)
                    if press.shift { backend.input.key(udid: udid, usage: shift, down: false) }
                    await sleep(.milliseconds(20))
                    typed += 1
                }
            case .paste(let text):
                if let stopped = stop() { return stopped }
                do {
                    let open: any DevicePasteSession
                    if let paste { open = paste } else {
                        open = try await backend.beginPaste(udid)
                        paste = open
                    }
                    if let stopped = stop() { return stopped }
                    try await open.paste(text)
                } catch {
                    return .error("device_paste_failed: \(error.localizedDescription) \(typed) of \(total) characters were typed.")
                }
                typed += text.count
            }
        }
        return nil
    }

    private func readLogs(
        udid: String, since: Int, bundleID: String?, level: SimulatorLogLevel, includeApple: Bool, query: String?, limit: Int
    ) async -> AlasCLIResponse {
        let backend: any DeviceBackend
        let device: AgentDevice
        switch await bootedDevice(udid) {
        case .failure(let refusal): return refusal.response
        case .success(let found): (backend, device) = (found.backend, found.device)
        }
        do {
            return .text([Self.json(try await backend.logs(
                udid, name: device.name, since: since, appID: bundleID, level: level, includeApple: includeApple,
                query: query, limit: limit
            ))])
        } catch let missing as DeviceAppNotInstalled {
            return Self.notInstalled(missing.appID, on: device)
        } catch let error as DeviceToolError {
            return .error(error.message)
        } catch {
            return .error("device_logs_failed: \(error.localizedDescription)")
        }
    }

    private func settingsCall(_ body: () async throws -> AlasCLIResponse) async -> AlasCLIResponse {
        do {
            return try await body()
        } catch let error as DeviceToolError {
            return .error(error.message)
        } catch {
            return .error("device_settings_failed: \(error.localizedDescription)")
        }
    }

    private static func notInstalled(_ bundleID: String, on device: AgentDevice) -> AlasCLIResponse {
        .error("device_app_not_installed: \(bundleID) isn't installed on \(device.name).")
    }

    /// Runs the user's own operation on `udid`, such as installing and
    /// launching an app, in an input turn: it waits for agent input already
    /// queued, and agent input started meanwhile waits for it. Returns false
    /// without running it while an agent drives the simulator.
    func whileUserHoldsInput(udid: String, _ operation: () async -> Void) async -> Bool {
        if case .agent = driver(udid: udid) { return false }
        let turn = takeInputTurn(udid)
        defer { endInputTurn(udid, turn) }
        await waitForInputTurn(udid, turn)
        // Agent input that ran first makes it the driver.
        if case .agent = driver(udid: udid) { return false }
        await operation()
        return true
    }

    private func takeInputTurn(_ udid: String) -> UUID {
        let turn = UUID()
        inputTurns[udid, default: []].append(turn)
        return turn
    }

    private func waitForInputTurn(_ udid: String, _ turn: UUID) async {
        guard inputTurns[udid]?.first != turn else { return }
        await withCheckedContinuation { inputWaiters[turn] = $0 }
    }

    /// Gives the device to the next turn; a call that hasn't started waiting
    /// finds its turn first when it does.
    private func endInputTurn(_ udid: String, _ turn: UUID) {
        inputTurns[udid]?.removeAll { $0 == turn }
        if inputTurns[udid]?.isEmpty == true { inputTurns[udid] = nil }
        if let next = inputTurns[udid]?.first, let waiter = inputWaiters.removeValue(forKey: next) {
            waiter.resume()
        }
    }

    /// Every backend's devices; a backend that fails is left out unless all do.
    private func list() async -> AlasCLIResponse {
        var devices: [[String: Any]] = []
        var failure: (any Error)?
        var listed = false
        for backend in backends {
            do {
                for device in try await backend.devices() {
                    routes[device.id] = backend.platform
                    devices.append(device.json)
                }
                listed = true
            } catch {
                failure = failure ?? error
            }
        }
        if !listed, let failure { return .error("device_unavailable: \(failure.localizedDescription)") }
        return .text([Self.json(["devices": devices])])
    }

    /// The live backend of a platform, for views that change settings outside an agent's call.
    func backend(for platform: AgentDevice.Platform) -> (any DeviceBackend)? {
        backends.first { $0.platform == platform }
    }

    /// The input of the backend `udid` was last found in; by its shape before that.
    private func input(_ udid: String) -> DeviceInput? {
        let platform = routes[udid] ?? (AgentDevice.isSimulatorID(udid) ? .ios : .android)
        return (backends.first { $0.platform == platform } ?? backends.first)?.input
    }

    private func finish(_ udid: String, includeScreenshot: Bool, diff: Bool, sessionID: String) async -> AlasCLIResponse {
        guard diff else {
            guard includeScreenshot else { return .ok }
            await sleep(.milliseconds(300))
            return await screenshot(udid)
        }
        var reply = await diffReply(udid, sessionID: sessionID)
        // Taken after settling, so it shows the screen the diff describes. The
        // action already happened, so a failed screenshot is reported, not raised.
        if includeScreenshot {
            switch await screenshot(udid) {
            case .text(let parts):
                if let shot = (try? JSONSerialization.jsonObject(with: Data(parts.joined().utf8))) as? [String: Any] {
                    reply.merge(shot) { current, _ in current }
                }
            case .error(let message):
                reply["screenshot_error"] = message
            default:
                break
            }
        }
        return .text([Self.json(reply)])
    }

    private func withDiff(_ reply: [String: Any], udid: String, diff: Bool, sessionID: String) async -> [String: Any] {
        guard diff else { return reply }
        return reply.merging(await diffReply(udid, sessionID: sessionID)) { current, _ in current }
    }

    // MARK: Settle and diff

    /// Waits for the screen to settle, snapshots it, and diffs it with the
    /// screen this session last received, whose refs carry over; another
    /// session's last screen isn't one this agent knows, so it gets the whole
    /// screen. The input already landed, so failures here are reported, not raised.
    private func diffReply(_ udid: String, sessionID: String) async -> [String: Any] {
        let settled = await settle(udid)
        if userDriving(udid) { return ["settled": settled, "diff_error": "The user took over."] }
        if Task.isCancelled { return ["settled": settled, "diff_error": "The call was cancelled."] }
        do {
            let next = try await takeSnapshot(udid)
            let previous = snapshotSessions[udid] == sessionID ? snapshots[udid] : nil
            let diff = DeviceSnapshotDiff(previous: previous, next: next)
            let reply = diff.json()
            if (snapshots[udid]?.generation ?? 0) < next.generation {
                snapshots[udid] = diff.snapshot
                // A truncated reply left elements out, so it is no baseline.
                snapshotSessions[udid] = reply["truncated"] == nil ? sessionID : nil
            }
            return reply.merging(["settled": settled]) { current, _ in current }
        } catch {
            return ["settled": settled, "diff_error": Self.snapshotError(error)]
        }
    }

    /// Polls frames every 50 ms until 6 in a row look the same (300 ms);
    /// gives up after 60 polls (3 s). Counting polls keeps tests deterministic.
    private func settle(_ udid: String) async -> Bool {
        // Frames are compared with the first of the window, not the one before,
        // so a slow fade's small steps don't add up to "settled".
        var reference: DeviceFrameFingerprint?
        var same = 0
        for _ in 0..<60 {
            await sleep(.milliseconds(50))
            if userDriving(udid) || Task.isCancelled { return false }
            guard let surface = input(udid)?.lastFrame(udid: udid)?.surface,
                  let print = DeviceFrameFingerprint(surface) else { continue }
            if let reference, reference.matches(print) {
                same += 1
                if same >= 6 { return true }
            } else {
                reference = print
                same = 0
            }
        }
        return false
    }

    private func takeSnapshot(_ udid: String) async throws -> DeviceSnapshot {
        // Reserved before the await, so overlapping snapshots never share refs.
        let generation = (generations[udid] ?? 0) + 1
        generations[udid] = generation
        let platform = routes[udid] ?? (AgentDevice.isSimulatorID(udid) ? .ios : .android)
        guard let backend = backends.first(where: { $0.platform == platform }) ?? backends.first else {
            throw DeviceToolError(message: "device_not_found: No device \(udid). Call device_list.")
        }
        return try await backend.snapshot(udid, generation: generation)
    }

    private static func snapshotError(_ error: any Error) -> String {
        error.localizedDescription.hasPrefix("device_")
            ? error.localizedDescription : "device_unavailable: \(error.localizedDescription)"
    }

    // MARK: Targets

    private struct Failure: Error {
        let message: String
    }

    private func resolve(_ target: DeviceCommand.Target, udid: String) -> Result<DeviceScreenPoint, Failure> {
        switch target {
        case .ref(let ref):
            guard let snapshot = snapshots[udid] else {
                return .failure(Failure(message: "device_no_snapshot: Call device_snapshot before tapping a ref."))
            }
            guard let element = snapshot.element(ref: ref) else {
                return .failure(Failure(
                    message: "device_stale_ref: \(ref) is not in the latest device_snapshot of this device. Take a new snapshot."
                ))
            }
            return .success(panelPoint(snapshot.center(of: element), udid: udid))
        case .point(let x, let y):
            return screenPoint(x: x, y: y, udid: udid).map { panelPoint($0, udid: udid) }
        }
    }

    /// Snapshot refs, screenshot pixels and swipe directions are upright; touches go to the portrait panel.
    private func panelPoint(_ upright: DeviceScreenPoint, udid: String) -> DeviceScreenPoint {
        (input(udid)?.lastFrame(udid: udid)?.orientation ?? .portrait).panelPoint(upright)
    }

    private func swipeEnds(
        _ gesture: DeviceCommand.Swipe, udid: String
    ) -> Result<(DeviceScreenPoint, DeviceScreenPoint), Failure> {
        let upright: Result<(DeviceScreenPoint, DeviceScreenPoint), Failure>
        switch gesture {
        case .direction(let direction):
            let (low, high) = (0.25, 0.75)
            upright = switch direction {
            case .up: .success((.init(x: 0.5, y: high), .init(x: 0.5, y: low)))
            case .down: .success((.init(x: 0.5, y: low), .init(x: 0.5, y: high)))
            case .left: .success((.init(x: high, y: 0.5), .init(x: low, y: 0.5)))
            case .right: .success((.init(x: low, y: 0.5), .init(x: high, y: 0.5)))
            }
        case .points(let fromX, let fromY, let toX, let toY):
            upright = screenPoint(x: fromX, y: fromY, udid: udid).flatMap { from in
                screenPoint(x: toX, y: toY, udid: udid).map { to in (from, to) }
            }
        }
        return upright.map { (panelPoint($0.0, udid: udid), panelPoint($0.1, udid: udid)) }
    }

    /// Pixels in the device's latest screenshot, as a fraction of the screen.
    private func screenPoint(x: Double, y: Double, udid: String) -> Result<DeviceScreenPoint, Failure> {
        guard let size = screenshotSizes[udid] else {
            return .failure(Failure(
                message: "device_no_screenshot: x and y are pixels in the latest device_screenshot; take one first."
            ))
        }
        guard x <= size.width, y <= size.height else {
            return .failure(Failure(
                message: "device_out_of_bounds: (\(x), \(y)) is outside the latest screenshot, which is \(Int(size.width))×\(Int(size.height))."
            ))
        }
        return .success(DeviceScreenPoint(x: x / size.width, y: y / size.height))
    }

    // MARK: Screenshots and leases

    private func screenshot(_ udid: String) async -> AlasCLIResponse {
        var frame = input(udid)?.lastFrame(udid: udid)
        var waited = 0
        while frame == nil, waited < 100 {
            await sleep(.milliseconds(50))
            waited += 1
            frame = input(udid)?.lastFrame(udid: udid)
        }
        guard let frame else {
            return .error("device_unavailable: The device sent no frame. Try again in a moment.")
        }
        guard let png = DeviceScreenshot.png(frame, maxLongEdge: 1280) else {
            return .error("device_unavailable: The screenshot could not be encoded.")
        }
        screenshotSizes[udid] = (Double(png.width), Double(png.height))
        return .text([Self.json([
            "width": png.width,
            "height": png.height,
            "image": ["mime_type": "image/png", "data": png.data.base64EncodedString()],
        ])])
    }

    /// Keeps the device's stream running for the agent until `leaseWindow`
    /// after its last call ends, so screenshots work with the Devices tab
    /// closed. A call still running keeps it, however long it takes.
    private func renewLease(_ udid: String) {
        guard let input = input(udid) else { return }
        let token = leases[udid]?.token
            ?? input.subscribe(udid: udid, onFrame: { _ in }, onStop: { [weak self] _ in self?.dropLease(udid) })
        leases[udid]?.release.cancel()
        let window = leaseWindow
        let release = Task { [weak self] in
            await self?.sleep(window)
            guard !Task.isCancelled, let self, self.leases[udid]?.token == token,
                  (self.inFlight[udid] ?? 0) == 0 else { return }
            self.leases[udid] = nil
            input.unsubscribe(udid: udid, token: token)
        }
        leases[udid] = (token, release)
    }

    /// A stream that stopped (it failed, or the service died) is no longer the
    /// agent's: dropping the lease lets the next call or the tab's Retry start it again.
    private func dropLease(_ udid: String) {
        guard let lease = leases.removeValue(forKey: udid) else { return }
        lease.release.cancel()
        input(udid)?.unsubscribe(udid: udid, token: lease.token)
    }

    // MARK: JSON

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
