import Foundation
#if canImport(notify)
import notify
#endif
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Cross-process "something changed for this worktree's ACP DB" ping.
/// Payload-free by design — observers re-read the DB to learn what
/// changed. Abstracted behind a protocol so tests can inject a
/// synchronous notifier.
public protocol ACPChangeNotifier: AnyObject {
    func post()
    func subscribe(_ handler: @escaping () -> Void) -> Int32
    func unsubscribe(_ token: Int32)
}

public final class DarwinChangeNotifier: ACPChangeNotifier {
    private let name: String
    // Dedicated serial queue for notify(3) delivery. Handlers may run
    // off the main thread — callers must hop to MainActor as needed.
    private let deliveryQueue = DispatchQueue(label: "io.alas.acp.notify")

    public init(worktreeId: String, channel: String? = nil) {
        self.name = Self.channelName(worktreeId: worktreeId, channel: channel)
    }

    /// notify(3) names must be short, ASCII, and reverse-DNS-ish. Hash
    /// the (possibly long, space-containing) worktree id into a stable
    /// 64-bit suffix so any worktree maps to one safe channel.
    public static func channelName(worktreeId: String, channel: String? = nil) -> String {
        var hash: UInt64 = 1469598103934665603   // FNV-1a offset basis
        for byte in worktreeId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let name = "io.alas.acp." + String(hash, radix: 16)
        return channel.map { name + "." + $0 } ?? name
    }

    #if canImport(notify)
    public func post() {
        notify_post(name)
    }

    public func subscribe(_ handler: @escaping () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, deliveryQueue) { _ in
            handler()
        }
        return token
    }

    public func unsubscribe(_ token: Int32) {
        notify_cancel(token)
    }
    #else
    // No notify(3) here. A Linux host is one process, so delivering within
    // it reaches every observer there is.
    public func post() {
        for handler in InProcessChannels.handlers(for: name) {
            // As with notify(3), handlers run on the delivery queue and hop on their own.
            nonisolated(unsafe) let handler = handler
            deliveryQueue.async { handler() }
        }
    }

    public func subscribe(_ handler: @escaping () -> Void) -> Int32 {
        InProcessChannels.add(handler, for: name)
    }

    public func unsubscribe(_ token: Int32) {
        InProcessChannels.remove(token)
    }
    #endif
}

#if !canImport(notify)
private enum InProcessChannels {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var nextToken: Int32 = 1
    nonisolated(unsafe) private static var subscribers: [Int32: (name: String, handler: () -> Void)] = [:]

    static func add(_ handler: @escaping () -> Void, for name: String) -> Int32 {
        lock.withLock {
            let token = nextToken
            nextToken += 1
            subscribers[token] = (name, handler)
            return token
        }
    }

    static func remove(_ token: Int32) {
        lock.withLock { subscribers[token] = nil }
    }

    static func handlers(for name: String) -> [() -> Void] {
        lock.withLock { subscribers.values.filter { $0.name == name }.map(\.handler) }
    }
}
#endif
