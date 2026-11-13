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

/// Runs the `device_*` tools for agents, and tracks who drives each
/// simulator so the Devices tab can show it and the user can take over.
@MainActor
@Observable
final class DeviceAgentControl {
    static let disabled =
        "device_disabled: Agents can't use iOS simulators. Ask the user to turn on Settings › Computer Use › Let agents use iOS simulators."
    static let userDriving = "device_user_active: The user took over this simulator. Try again after they hand it back."
    static let stillDriving = "device_user_active: The user is still driving this simulator. Try again in a minute."
    /// The agent cancelled the call, or its MCP server went away.
    static let cancelled = "device_cancelled: The call was cancelled."

    private struct AgentCall {
        let sessionID: String
        let tool: String
        let at: Date
    }

    @ObservationIgnored private let input: DeviceInput
    @ObservationIgnored private let devices: () async throws -> [SimulatorDevice]
    @ObservationIgnored private let boot: (String) async throws -> Void
    @ObservationIgnored private let install: (String, URL) async throws -> Void
    @ObservationIgnored private let launch: (String, String) async throws -> Int32
    @ObservationIgnored private let settings: any SimulatorSettingsControl
    @ObservationIgnored private let logs: any SimulatorLogsControl
    @ObservationIgnored private let pasteboard: DevicePasteboard
    @ObservationIgnored private let recorder: DeviceRecorder
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private let leaseWindow: Duration
    /// How long a call waits for the user to hand a simulator back; under
    /// Codex's 60-second limit on a tool call.
    @ObservationIgnored private let holdLimit: Duration

    /// A released call carries its input turn when it needs one.
    private enum Hold: Sendable { case go(inputTurn: UUID?), timedOut, cancelled }
    private struct HeldCall {
        let id: UUID
        let sessionID: String
        let isInput: Bool
        let resume: CheckedContinuation<Hold, Never>
        let timer: Task<Void, Never>
    }

    private var lastCalls: [String: AgentCall] = [:]
    private var inFlight: [String: Int] = [:]
    private var takenOver: Set<String> = []
    /// Calls waiting for the user to hand each simulator back, in arrival order.
    private var held: [String: [HeldCall]] = [:]
    @ObservationIgnored private var snapshots: [String: DeviceSnapshot] = [:]
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var screenshotSizes: [String: (width: Double, height: Double)] = [:]
    @ObservationIgnored private var leases: [String: (token: UUID, release: Task<Void, Never>)] = [:]
    /// Each device's input turns, in the order they were taken; the first runs.
    @ObservationIgnored private var inputTurns: [String: [UUID]] = [:]
    /// Calls waiting for their turn to come up.
    @ObservationIgnored private var inputWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(
        input: DeviceInput,
        devices: @escaping () async throws -> [SimulatorDevice],
        boot: @escaping (String) async throws -> Void,
        install: @escaping (String, URL) async throws -> Void,
        launch: @escaping (String, String) async throws -> Int32,
        settings: any SimulatorSettingsControl,
        logs: any SimulatorLogsControl,
        pasteboard: DevicePasteboard,
        recorder: DeviceRecorder,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        leaseWindow: Duration = .seconds(60),
        holdLimit: Duration = .seconds(50)
    ) {
        self.input = input
        self.devices = devices
        self.boot = boot
        self.install = install
        self.launch = launch
        self.settings = settings
        self.logs = logs
        self.pasteboard = pasteboard
        self.recorder = recorder
        self.now = now
        self.sleep = sleep
        self.leaseWindow = leaseWindow
        self.holdLimit = holdLimit
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
        // Input turns are taken here, in arrival order: a released call still
        // lists devices before it runs, and those listings can finish in any order.
        for call in held.removeValue(forKey: udid) ?? [] {
            call.timer.cancel()
            call.resume.resume(returning: .go(inputTurn: call.isInput ? takeInputTurn(udid) : nil))
        }
    }

    /// Sessions whose calls wait for the user to hand `udid` back, first to arrive first.
    func waitingSessions(udid: String) -> [String] {
        held[udid]?.map(\.sessionID) ?? []
    }

    /// Waits while the user drives `udid`: until they hand it back, the hold
    /// limit passes, or the calling task is cancelled.
    private func holdWhileTakenOver(_ udid: String, sessionID: String, isInput: Bool) async -> Hold {
        guard takenOver.contains(udid) else { return .go(inputTurn: nil) }
        guard !Task.isCancelled else { return .cancelled }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let limit = holdLimit
                let timer = Task { [weak self] in
                    await self?.sleep(limit)
                    guard !Task.isCancelled else { return }
                    self?.release(udid, id: id, as: .timedOut)
                }
                held[udid, default: []].append(HeldCall(
                    id: id, sessionID: sessionID, isInput: isInput, resume: continuation, timer: timer
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(udid, id: id, as: .cancelled) }
        }
    }

    private func release(_ udid: String, id: UUID, as outcome: Hold) {
        guard var calls = held[udid], let index = calls.firstIndex(where: { $0.id == id }) else { return }
        let call = calls.remove(at: index)
        held[udid] = calls.isEmpty ? nil : calls
        call.timer.cancel()
        call.resume.resume(returning: outcome)
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
        if case .clipboard(_, nil) = command {
            switch await bootedDevice(udid) {
            case .failure(let refusal): return refusal.response
            case .success:
                do { return .text([Self.json(["text": try await pasteboard.read(udid: udid)])]) } catch {
                    return .error("device_clipboard_failed: \(error.localizedDescription)")
                }
            }
        }
        // Touches and keys from two calls must not interleave on one simulator,
        // so input calls to a device run one at a time, in arrival order;
        // installing and launching take their turn too.
        let isInput = switch command {
        case .tap, .swipe, .type, .button, .install, .launch,
             .setAppearance, .setPermission, .setLocation, .push, .openURL, .clipboard, .rotate: true
        case .list, .open, .snapshot, .screenshot, .logs, .record: false
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
        let listed: [SimulatorDevice]
        do {
            listed = try await devices()
        } catch {
            return .error("device_unavailable: \(error.localizedDescription)")
        }
        guard var device = listed.first(where: { $0.udid == udid }) else {
            return .error("device_not_found: No iOS simulator \(udid). Call device_list.")
        }
        if userDriving(udid) { return .error(Self.userDriving) }

        lastCalls[udid] = AgentCall(sessionID: sessionID, tool: command.toolName, at: now())
        inFlight[udid, default: 0] += 1
        var leased = false
        defer {
            inFlight[udid, default: 1] -= 1
            lastCalls[udid] = AgentCall(sessionID: sessionID, tool: command.toolName, at: now())
            // The idle window starts when the call ends, not when it began.
            if leased { renewLease(udid) }
        }

        if case .open = command, device.state != .booted {
            do {
                try await boot(udid)
                device = SimulatorDevice(udid: udid, name: device.name, runtimeName: device.runtimeName, state: .booted)
            } catch {
                return .error("device_not_booted: \(error.localizedDescription)")
            }
        }
        guard device.state == .booted else {
            return .error("device_not_booted: \(device.name) is shut down. Call device_open to boot it.")
        }
        renewLease(udid)
        leased = true

        if let inputTurn {
            await waitForInputTurn(udid, inputTurn)
            if Task.isCancelled { return .error(Self.cancelled) }
            if userDriving(udid) { return .error(Self.userDriving) }
        }

        switch command {
        case .list:
            return await list()
        case .open:
            return .text([Self.json(Self.describe(device))])
        case .snapshot(_, let query, let limit):
            do {
                // Reserved before the await, so overlapping snapshots never share refs.
                let generation = (generations[udid] ?? 0) + 1
                generations[udid] = generation
                let snapshot = try DeviceSnapshot.parse(try await input.describe(udid: udid), generation: generation)
                // One that finishes after a newer snapshot doesn't replace it.
                if (snapshots[udid]?.generation ?? 0) < generation { snapshots[udid] = snapshot }
                return .text([snapshot.json(query: query, limit: limit)])
            } catch {
                return .error(error.localizedDescription.hasPrefix("device_")
                    ? error.localizedDescription : "device_unavailable: \(error.localizedDescription)")
            }
        case .screenshot:
            return await screenshot(udid)
        case .tap(_, let target, let includeScreenshot):
            let point: DeviceScreenPoint
            switch resolve(target, udid: udid) {
            case .success(let resolved): point = resolved
            case .failure(let failure): return .error(failure.message)
            }
            input.touch(udid: udid, phase: "begin", point: point)
            await sleep(.milliseconds(50))
            input.touch(udid: udid, phase: "end", point: point)
            return await finish(udid, includeScreenshot: includeScreenshot)
        case .swipe(_, let gesture, let durationMs, let includeScreenshot):
            let from: DeviceScreenPoint
            let to: DeviceScreenPoint
            switch swipeEnds(gesture, udid: udid) {
            case .success(let ends): (from, to) = ends
            case .failure(let failure): return .error(failure.message)
            }
            let steps = max(1, durationMs / 16)
            var current = from
            input.touch(udid: udid, phase: "begin", point: from)
            for step in 1...steps {
                await sleep(.milliseconds(16))
                if userDriving(udid) || Task.isCancelled {
                    input.touch(udid: udid, phase: "end", point: current)
                    return .error(Task.isCancelled ? Self.cancelled : Self.userDriving)
                }
                let fraction = Double(step) / Double(steps)
                current = DeviceScreenPoint(
                    x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction
                )
                input.touch(udid: udid, phase: step == steps ? "end" : "move", point: current)
            }
            return await finish(udid, includeScreenshot: includeScreenshot)
        case .type(_, let text, let includeScreenshot):
            let runs = DeviceTextInput.runs(for: text)
            let total = runs.reduce(0) { $0 + $1.characterCount }
            var paste: DevicePasteboard.Paste?
            let stopped = await typeRuns(runs, total: total, udid: udid, paste: &paste)
            if let paste { await pasteboard.close(paste) }
            if let stopped { return stopped }
            return await finish(udid, includeScreenshot: includeScreenshot)
        case .button(_, let name, let includeScreenshot):
            input.button(udid: udid, name: name.rawValue)
            return await finish(udid, includeScreenshot: includeScreenshot)
        case .install(_, let appPath):
            let app: SimulatorAppBundle
            do {
                app = try SimulatorAppBundle.read(URL(fileURLWithPath: appPath))
            } catch let problem as SimulatorAppBundle.Problem {
                return .error(problem.message(udid: udid))
            } catch {
                return .error("device_app_invalid: \(error.localizedDescription)")
            }
            do {
                try await install(udid, app.url)
            } catch {
                return .error("device_install_failed: \(error.localizedDescription)")
            }
            return .text([Self.json(["bundle_id": app.bundleID, "name": app.name])])
        case .launch(_, let bundleID):
            do {
                return .text([Self.json(["pid": Int(try await launch(udid, bundleID))])])
            } catch SimulatorLaunchError.notInstalled {
                return Self.notInstalled(bundleID, on: device)
            } catch {
                return .error("device_launch_failed: \(error.localizedDescription)")
            }
        case .setAppearance(_, let appearance, let textSize, let increaseContrast):
            return await settingsCall {
                .text([Self.json(try await settings.setDisplay(
                    udid: udid, appearance: appearance, textSize: textSize, increaseContrast: increaseContrast
                ).json)])
            }
        case .setPermission(_, let bundleID, let service, let action):
            guard await settings.isInstalled(udid: udid, bundleID: bundleID) else { return Self.notInstalled(bundleID, on: device) }
            return await settingsCall {
                try await settings.setPermission(udid: udid, bundleID: bundleID, service: service, action: action)
                return .text([Self.json(["ok": true])])
            }
        case .setLocation(_, let location):
            return await settingsCall {
                try await settings.setLocation(udid: udid, location)
                return .text([Self.json(["ok": true])])
            }
        case .push(_, let bundleID, let payload):
            guard await settings.isInstalled(udid: udid, bundleID: bundleID) else { return Self.notInstalled(bundleID, on: device) }
            return await settingsCall {
                try await settings.push(udid: udid, bundleID: bundleID, payload: Data(payload.utf8))
                return .text([Self.json(["ok": true])])
            }
        case .openURL(_, let url):
            return await settingsCall {
                try await settings.openURL(udid: udid, url: url)
                return .text([Self.json(["ok": true])])
            }
        case .clipboard(_, let text):
            do {
                try await pasteboard.write(udid: udid, text: text ?? "")
                return .text([Self.json(["ok": true])])
            } catch {
                return .error("device_clipboard_failed: \(error.localizedDescription)")
            }
        case .rotate(_, let orientation):
            return await rotate(udid, to: orientation)
        case .logs, .record:
            // Answered before the hold.
            return .error("device_unavailable: The call took the wrong path.")
        }
    }

    /// Turns the device, then waits up to 2 s for a frame in the new
    /// orientation; an app that supports only portrait never sends one.
    private func rotate(_ udid: String, to orientation: DeviceScreenOrientation) async -> AlasCLIResponse {
        // The service rotates through the device's stream, which the lease just started.
        for _ in 0..<100 where input.lastFrame(udid: udid) == nil {
            await sleep(.milliseconds(50))
        }
        do {
            try await input.rotate(udid: udid, to: orientation)
        } catch {
            return .error("device_rotate_failed: \(error.localizedDescription)")
        }
        for _ in 0..<40 where input.lastFrame(udid: udid)?.orientation != orientation {
            await sleep(.milliseconds(50))
        }
        let interface = input.lastFrame(udid: udid)?.orientation ?? .portrait
        return .text([Self.json(["device": orientation.rawValue, "interface": interface.rawValue])])
    }

    private func record(udid: String, start: Bool, sessionID: String) async -> AlasCLIResponse {
        let device: SimulatorDevice
        switch await bootedDevice(udid) {
        case .failure(let refusal): return refusal.response
        case .success(let found): device = found
        }
        let owner = DeviceRecorder.Owner.agent(sessionID: sessionID)
        do throws(DeviceRecorder.Failure) {
            if start {
                try recorder.start(udid: udid, owner: owner, file: DeviceRecorder.agentFile(udid: udid, now: now()))
                return .text([Self.json(["recording": true])])
            }
            let finished = try await recorder.stop(udid: udid, owner: owner)
            return .text([Self.json(["path": finished.file.path, "seconds": (finished.seconds * 10).rounded() / 10])])
        } catch {
            switch error {
            case .busy(let other):
                let who = other == .user ? "The user" : "Another agent session"
                return .error("device_recording_busy: \(who) is recording \(device.name).")
            case .notRecording:
                return .error("device_not_recording: No recording of \(device.name) by this session is running.")
            case .failed(let reason):
                return .error("device_record_failed: \(reason)")
            }
        }
    }

    /// Why a call can't use a simulator.
    private struct Refusal: Error {
        let response: AlasCLIResponse
    }

    private func bootedDevice(_ udid: String) async -> Result<SimulatorDevice, Refusal> {
        let device: SimulatorDevice
        do {
            guard let found = try await devices().first(where: { $0.udid == udid }) else {
                return .failure(Refusal(response: .error("device_not_found: No iOS simulator \(udid). Call device_list.")))
            }
            device = found
        } catch {
            return .failure(Refusal(response: .error("device_unavailable: \(error.localizedDescription)")))
        }
        guard device.state == .booted else {
            return .failure(Refusal(response: .error("device_not_booted: \(device.name) is shut down. Call device_open to boot it.")))
        }
        return .success(device)
    }

    /// Types key runs and pastes the rest, opening the paste on the first
    /// paste run. Returns the response that stopped it, or nil when all of it went in.
    private func typeRuns(
        _ runs: [DeviceTextInput.Run], total: Int, udid: String, paste: inout DevicePasteboard.Paste?
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
                    if press.shift { input.key(udid: udid, usage: shift, down: true) }
                    input.key(udid: udid, usage: press.usage, down: true)
                    input.key(udid: udid, usage: press.usage, down: false)
                    if press.shift { input.key(udid: udid, usage: shift, down: false) }
                    await sleep(.milliseconds(20))
                    typed += 1
                }
            case .paste(let text):
                if let stopped = stop() { return stopped }
                do {
                    let open: DevicePasteboard.Paste
                    if let paste { open = paste } else {
                        open = try await pasteboard.open(udid: udid, keepText: true)
                        paste = open
                    }
                    if let stopped = stop() { return stopped }
                    try await pasteboard.paste(text, in: open)
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
        let device: SimulatorDevice
        switch await bootedDevice(udid) {
        case .failure(let refusal): return refusal.response
        case .success(let found): device = found
        }
        var app = bundleID
        if app == nil { app = await logs.frontmostApp(udid: udid) }
        guard let app else { return .error("device_no_app: No app is in front on \(device.name). Pass bundle_id.") }
        do {
            guard let executable = try await logs.executables(udid: udid)[app] else { return Self.notInstalled(app, on: device) }
            let all = try await logs.logShow(
                udid: udid, query: SimulatorLogQuery(executable: executable, level: level, includeApple: includeApple), seconds: since
            )
            let matching = query.map { query in all.filter { $0.matches(query) } } ?? all
            let crashes = await logs.crashReports(udid: udid, bundleID: app, since: now().addingTimeInterval(-Double(since)))
            return .text([Self.json([
                "app": app,
                "lines": matching.suffix(limit).map(\.json),
                "truncated": matching.count > limit,
                "crashes": crashes.map(\.json),
            ])])
        } catch {
            return .error("device_logs_failed: \(error.localizedDescription)")
        }
    }

    private func settingsCall(_ body: () async throws -> AlasCLIResponse) async -> AlasCLIResponse {
        do {
            return try await body()
        } catch {
            return .error("device_settings_failed: \(error.localizedDescription)")
        }
    }

    private static func notInstalled(_ bundleID: String, on device: SimulatorDevice) -> AlasCLIResponse {
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

    private func list() async -> AlasCLIResponse {
        do {
            return .text([Self.json(["devices": try await devices().map(Self.describe)])])
        } catch {
            return .error("device_unavailable: \(error.localizedDescription)")
        }
    }

    private func finish(_ udid: String, includeScreenshot: Bool) async -> AlasCLIResponse {
        guard includeScreenshot else { return .ok }
        await sleep(.milliseconds(300))
        return await screenshot(udid)
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
        (input.lastFrame(udid: udid)?.orientation ?? .portrait).panelPoint(upright)
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
        var frame = input.lastFrame(udid: udid)
        var waited = 0
        while frame == nil, waited < 100 {
            await sleep(.milliseconds(50))
            waited += 1
            frame = input.lastFrame(udid: udid)
        }
        guard let frame else {
            return .error("device_unavailable: The simulator sent no frame. Try again in a moment.")
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
        let token = leases[udid]?.token
            ?? input.subscribe(udid: udid, onFrame: { _ in }, onStop: { [weak self] _ in self?.dropLease(udid) })
        leases[udid]?.release.cancel()
        let window = leaseWindow
        let release = Task { [weak self] in
            await self?.sleep(window)
            guard !Task.isCancelled, let self, self.leases[udid]?.token == token,
                  (self.inFlight[udid] ?? 0) == 0 else { return }
            self.leases[udid] = nil
            self.input.unsubscribe(udid: udid, token: token)
        }
        leases[udid] = (token, release)
    }

    /// A stream that stopped (it failed, or the service died) is no longer the
    /// agent's: dropping the lease lets the next call or the tab's Retry start it again.
    private func dropLease(_ udid: String) {
        guard let lease = leases.removeValue(forKey: udid) else { return }
        lease.release.cancel()
        input.unsubscribe(udid: udid, token: lease.token)
    }

    // MARK: JSON

    private static func describe(_ device: SimulatorDevice) -> [String: Any] {
        let state: String = switch device.state {
        case .booted: "booted"
        case .booting: "booting"
        case .shutdown: "shutdown"
        case .shuttingDown: "shutting_down"
        case .other(let value): value
        }
        return ["udid": device.udid, "name": device.name, "runtime": device.runtimeName, "state": state]
    }

    private static func json(_ object: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
