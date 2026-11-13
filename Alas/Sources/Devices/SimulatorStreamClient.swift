import AlasCore
import Foundation
import IOSurface

/// A simulator frame: the pixels in the portrait panel's layout, and the
/// interface orientation they show.
struct DeviceFrame {
    let surface: IOSurface
    let orientation: DeviceScreenOrientation
}

/// Alas's side of AlasSimService: one XPC connection, with each device's
/// frames fanned out to the screens showing it.
@MainActor
final class SimulatorStreamClient {
    private struct Screen {
        let onFrame: @MainActor (DeviceFrame) -> Void
        let onStop: @MainActor (String) -> Void
    }

    private var connection: NSXPCConnection?
    private var subscriptions = StreamSubscriptions()
    private var screens: [String: [UUID: Screen]] = [:]
    private var lastFrames: [String: DeviceFrame] = [:]
    /// The device orientation Alas last turned each simulator to.
    private var deviceOrientations: [String: DeviceScreenOrientation] = [:]

    func subscribe(
        udid: String,
        onFrame: @escaping @MainActor (DeviceFrame) -> Void,
        onStop: @escaping @MainActor (String) -> Void
    ) -> UUID {
        let token = UUID()
        screens[udid, default: [:]][token] = Screen(onFrame: onFrame, onStop: onStop)
        if subscriptions.add(udid) == .start { start(udid) }
        return token
    }

    func unsubscribe(udid: String, token: UUID) {
        screens[udid]?[token] = nil
        if screens[udid]?.isEmpty == true { screens[udid] = nil }
        if subscriptions.remove(udid) == .stop {
            lastFrames[udid] = nil
            service()?.stopStream(udid: udid)
        }
    }

    func touch(udid: String, phase: String, point: DeviceScreenPoint) {
        service()?.touch(udid: udid, phase: phase, x: point.x, y: point.y)
    }

    func key(udid: String, usage: UInt32, down: Bool) {
        service()?.key(udid: udid, usage: usage, down: down)
    }

    func button(udid: String, name: String) {
        service()?.button(udid: udid, name: name)
    }

    /// The newest frame of a device someone is watching.
    func lastFrame(udid: String) -> DeviceFrame? {
        lastFrames[udid]
    }

    /// The orientation Alas last turned the device to; portrait until then.
    /// Simulators don't report it back.
    func deviceOrientation(udid: String) -> DeviceScreenOrientation {
        deviceOrientations[udid] ?? .portrait
    }

    /// Turns the device. Its stream must be running.
    func rotate(udid: String, to orientation: DeviceScreenOrientation) async throws {
        let connection = self.connection ?? connect()
        let failure: String? = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = Self.proxy(connection) { error in
                once.resume(throwing: SimulatorStreamError(message: "The simulator service stopped (\(error.localizedDescription))."))
            }
            guard let proxy else {
                once.resume(throwing: SimulatorStreamError(message: "The simulator service is not available."))
                return
            }
            proxy.rotate(udid: udid, orientation: orientation.deviceValue) { once.resume(returning: $0) }
        }
        if let failure { throw SimulatorStreamError(message: failure) }
        deviceOrientations[udid] = orientation
    }

    /// serve-sim's accessibility JSON for `udid`.
    func describe(udid: String) async throws -> Data {
        let connection = self.connection ?? connect()
        return try await withCheckedThrowingContinuation { continuation in
            // XPC calls either the reply or the error handler; `once` guards against both.
            let once = ResumeOnce(continuation)
            let proxy = Self.proxy(connection) { error in
                once.resume(throwing: SimulatorStreamError(
                    message: "device_unavailable: The simulator service stopped (\(error.localizedDescription))."
                ))
            }
            guard let proxy else {
                once.resume(throwing: SimulatorStreamError(message: "device_unavailable: The simulator service is not available."))
                return
            }
            proxy.describe(udid: udid) { data, error in
                if let data {
                    once.resume(returning: data)
                } else {
                    once.resume(throwing: SimulatorStreamError(
                        message: "device_unavailable: \(error ?? "The simulator did not describe its screen.")"
                    ))
                }
            }
        }
    }

    /// The bundle ID of the app in front, or nil when none is or the service can't tell.
    func frontmostApp(udid: String) async -> String? {
        let connection = self.connection ?? connect()
        let found: String?? = try? await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = Self.proxy(connection) { error in once.resume(throwing: error) }
            guard let proxy else {
                once.resume(returning: nil)
                return
            }
            proxy.frontmostApp(udid: udid) { once.resume(returning: $0) }
        }
        return found ?? nil
    }

    // Handlers are copied before they run: an onStop may unsubscribe, which changes `screens`.
    fileprivate func deliver(udid: String, frame: DeviceFrame) {
        lastFrames[udid] = frame
        for screen in Array(screens[udid]?.values ?? [:].values) { screen.onFrame(frame) }
    }

    private func stopped(udid: String, reason: String) {
        // A stream stops when its simulator shuts down; it boots in portrait.
        deviceOrientations[udid] = nil
        for screen in Array(screens[udid]?.values ?? [:].values) { screen.onStop(reason) }
    }

    private func start(_ udid: String) {
        service()?.startStream(udid: udid) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.stopped(udid: udid, reason: error) }
            }
        }
    }

    /// The service crashed or was killed. launchd starts it again on the next
    /// message, which Retry sends.
    private func connectionInterrupted() {
        for udid in subscriptions.active {
            stopped(udid: udid, reason: "The simulator stream stopped.")
        }
    }

    private func service() -> SimServiceProtocol? {
        let connection = self.connection ?? connect()
        return Self.proxy(connection) { _ in }
    }

    /// XPC runs `onError` on its own queue. It must be `@Sendable`, or a closure formed in
    /// this main-actor class inherits main-actor isolation and traps when XPC calls it.
    private nonisolated static func proxy(
        _ connection: NSXPCConnection, onError: @escaping @Sendable (any Error) -> Void
    ) -> SimServiceProtocol? {
        connection.remoteObjectProxyWithErrorHandler(onError) as? SimServiceProtocol
    }

    private func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: SimServiceName.bundleIdentifier)
        connection.remoteObjectInterface = NSXPCInterface(with: SimServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: SimFrameSink.self)
        connection.exportedObject = FrameSinkBridge(client: self)
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.connectionInterrupted() }
            }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.connection = nil
                    self?.connectionInterrupted()
                }
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

/// Resumes a continuation at most once, from whichever XPC callback comes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.withLock { continuation.take() }?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.withLock { continuation.take() }?.resume(throwing: error)
    }
}

struct SimulatorStreamError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Receives frames on the XPC queue and hands them to the main actor.
private final class FrameSinkBridge: NSObject, SimFrameSink {
    private weak var client: SimulatorStreamClient?

    init(client: SimulatorStreamClient) {
        self.client = client
    }

    func frame(udid: String, surface: IOSurface, orientation: String?) {
        DispatchQueue.main.async { [weak client] in
            MainActor.assumeIsolated {
                client?.deliver(udid: udid, frame: DeviceFrame(surface: surface, orientation: .init(frameName: orientation)))
            }
        }
    }
}
