import CoreVideo
import Foundation
import IOSurface
import ServeSimCore

/// Accepts Alas's connection and gives it a handler for its sessions.
final class SimServiceListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SimServiceProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: SimFrameSink.self)
        let handler = SimServiceHandler(connection: connection)
        connection.exportedObject = handler
        connection.invalidationHandler = { handler.stopAll() }
        connection.resume()
        return true
    }
}

/// The simulator sessions one Alas connection started, by UDID.
final class SimServiceHandler: NSObject, SimServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: AlasSimulatorSession] = [:]
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func startStream(udid: String, reply: @escaping @Sendable (String?) -> Void) {
        let session = AlasSimulatorSession(udid: udid)
        let previous = lock.withLock { () -> AlasSimulatorSession? in
            defer { sessions[udid] = session }
            return sessions[udid]
        }
        nonisolated(unsafe) let sink = connection?.remoteObjectProxy as? SimFrameSink
        Task {
            await previous?.stop()
            do {
                try await session.start { pixelBuffer in
                    guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
                    sink?.frame(udid: udid, surface: surface as IOSurface)
                }
                reply(nil)
            } catch {
                self.lock.withLock {
                    if self.sessions[udid] === session { self.sessions[udid] = nil }
                }
                reply(error.localizedDescription)
            }
        }
    }

    func stopStream(udid: String) {
        guard let session = lock.withLock({ sessions.removeValue(forKey: udid) }) else { return }
        Task { await session.stop() }
    }

    func touch(udid: String, phase: String, x: Double, y: Double) {
        guard let phase = AlasSimulatorSession.TouchPhase(rawValue: phase) else { return }
        session(udid)?.touch(phase, x: x, y: y)
    }

    func key(udid: String, usage: UInt32, down: Bool) {
        session(udid)?.key(usage: usage, down: down)
    }

    func button(udid: String, name: String) {
        session(udid)?.button(name)
    }

    func stopAll() {
        let all = lock.withLock { () -> [AlasSimulatorSession] in
            defer { sessions.removeAll() }
            return Array(sessions.values)
        }
        Task { for session in all { await session.stop() } }
    }

    private func session(_ udid: String) -> AlasSimulatorSession? {
        lock.withLock { sessions[udid] }
    }
}
