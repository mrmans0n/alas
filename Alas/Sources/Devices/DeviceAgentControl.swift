import AlasCore
import CoreImage
import Foundation
import IOSurface
import Observation

/// What the device controller needs from the simulator service.
/// `SimulatorStreamClient` is the real one.
@MainActor
protocol DeviceInput: AnyObject {
    func subscribe(
        udid: String,
        onFrame: @escaping @MainActor (IOSurface) -> Void,
        onStop: @escaping @MainActor (String) -> Void
    ) -> UUID
    func unsubscribe(udid: String, token: UUID)
    func touch(udid: String, phase: String, point: DeviceScreenPoint)
    func key(udid: String, usage: UInt32, down: Bool)
    func button(udid: String, name: String)
    func describe(udid: String) async throws -> Data
    func lastFrame(udid: String) -> IOSurface?
}

extension SimulatorStreamClient: DeviceInput {}

/// Runs the `device_*` tools for agents, and tracks who drives each
/// simulator so the Device tab can show it and the user can take over.
@MainActor
@Observable
final class DeviceAgentControl {
    static let disabled =
        "device_disabled: Device control is off. Ask the user to turn on Settings › Advanced › Experiments › Let agents use the device."
    static let userDriving = "device_user_active: The user is driving this device. Try again after they hand it back."

    private struct AgentCall {
        let sessionID: String
        let tool: String
        let at: Date
    }

    @ObservationIgnored private let input: DeviceInput
    @ObservationIgnored private let devices: () async throws -> [SimulatorDevice]
    @ObservationIgnored private let boot: (String) async throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private let leaseWindow: Duration

    private var lastCalls: [String: AgentCall] = [:]
    private var inFlight: [String: Int] = [:]
    private var takenOver: Set<String> = []
    @ObservationIgnored private var snapshots: [String: DeviceSnapshot] = [:]
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var screenshotSizes: [String: (width: Double, height: Double)] = [:]
    @ObservationIgnored private var leases: [String: (token: UUID, release: Task<Void, Never>)] = [:]
    @ObservationIgnored private let imageContext = CIContext()

    init(
        input: DeviceInput,
        devices: @escaping () async throws -> [SimulatorDevice],
        boot: @escaping (String) async throws -> Void,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        leaseWindow: Duration = .seconds(60)
    ) {
        self.input = input
        self.devices = devices
        self.boot = boot
        self.now = now
        self.sleep = sleep
        self.leaseWindow = leaseWindow
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
    }

    private func userDriving(_ udid: String) -> Bool {
        VMDriver.decision(for: driver(udid: udid)) == .userDriving
    }

    // MARK: Calls

    func perform(_ command: DeviceCommand, sessionID: String) async -> AlasCLIResponse {
        guard let udid = command.udid else { return await list() }
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
                if userDriving(udid) {
                    input.touch(udid: udid, phase: "end", point: current)
                    return .error(Self.userDriving)
                }
                let fraction = Double(step) / Double(steps)
                current = DeviceScreenPoint(
                    x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction
                )
                input.touch(udid: udid, phase: step == steps ? "end" : "move", point: current)
            }
            return await finish(udid, includeScreenshot: includeScreenshot)
        case .type(_, let text, let includeScreenshot):
            let presses: [DeviceTextInput.Press]
            switch DeviceTextInput.presses(for: text) {
            case .success(let resolved): presses = resolved
            case .failure(let failure):
                return .error("device_type_unsupported: device_type types ASCII only; it can't type \"\(failure.character)\".")
            }
            let shift: UInt32 = 0xE1
            for press in presses {
                if userDriving(udid) { return .error(Self.userDriving) }
                if press.shift { input.key(udid: udid, usage: shift, down: true) }
                input.key(udid: udid, usage: press.usage, down: true)
                input.key(udid: udid, usage: press.usage, down: false)
                if press.shift { input.key(udid: udid, usage: shift, down: false) }
                await sleep(.milliseconds(20))
            }
            return await finish(udid, includeScreenshot: includeScreenshot)
        case .button(_, let name, let includeScreenshot):
            input.button(udid: udid, name: name.rawValue)
            return await finish(udid, includeScreenshot: includeScreenshot)
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
            return .success(snapshot.center(of: element))
        case .point(let x, let y):
            return screenPoint(x: x, y: y, udid: udid)
        }
    }

    private func swipeEnds(
        _ gesture: DeviceCommand.Swipe, udid: String
    ) -> Result<(DeviceScreenPoint, DeviceScreenPoint), Failure> {
        switch gesture {
        case .direction(let direction):
            let (low, high) = (0.25, 0.75)
            switch direction {
            case .up: return .success((.init(x: 0.5, y: high), .init(x: 0.5, y: low)))
            case .down: return .success((.init(x: 0.5, y: low), .init(x: 0.5, y: high)))
            case .left: return .success((.init(x: high, y: 0.5), .init(x: low, y: 0.5)))
            case .right: return .success((.init(x: low, y: 0.5), .init(x: high, y: 0.5)))
            }
        case .points(let fromX, let fromY, let toX, let toY):
            return screenPoint(x: fromX, y: fromY, udid: udid).flatMap { from in
                screenPoint(x: toX, y: toY, udid: udid).map { to in (from, to) }
            }
        }
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
        let image = CIImage(ioSurface: frame)
        let scale = min(1, 1280 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = scaled.extent.integral
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let png = imageContext.pngRepresentation(of: scaled.cropped(to: bounds), format: .RGBA8, colorSpace: colorSpace)
        else { return .error("device_unavailable: The screenshot could not be encoded.") }
        screenshotSizes[udid] = (Double(bounds.width), Double(bounds.height))
        return .text([Self.json([
            "width": Int(bounds.width),
            "height": Int(bounds.height),
            "image": ["mime_type": "image/png", "data": png.base64EncodedString()],
        ])])
    }

    /// Keeps the device's stream running for the agent until `leaseWindow`
    /// after its last call ends, so screenshots work with the Device tab
    /// closed. A call still running keeps it, however long it takes.
    private func renewLease(_ udid: String) {
        let token = leases[udid]?.token
            ?? input.subscribe(udid: udid, onFrame: { _ in }, onStop: { _ in })
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
