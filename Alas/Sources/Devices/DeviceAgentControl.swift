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
             .setAppearance, .setAccessibility, .setPermission, .setLocation, .push, .openURL, .clipboard, .rotate: true
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
        case .tap, .swipe, .type, .button, .screenshot, .rotate, .clipboard: true
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
                current = DeviceScreenPoint(
                    x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction
                )
                backend.input.touch(udid: udid, phase: step == steps ? "end" : "move", point: current)
            }
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
        case .logs, .record:
            // Answered before the hold.
            return .error("device_unavailable: The call took the wrong path.")
        }
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
