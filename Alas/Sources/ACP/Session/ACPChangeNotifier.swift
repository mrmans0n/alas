import Foundation
import notify

/// Cross-process "something changed for this worktree's ACP DB" ping.
/// Payload-free by design — observers re-read the DB to learn what
/// changed. Abstracted behind a protocol so tests can inject a
/// synchronous notifier.
protocol ACPChangeNotifier: AnyObject {
    func post()
    func subscribe(_ handler: @escaping () -> Void) -> Int32
    func unsubscribe(_ token: Int32)
}

final class DarwinChangeNotifier: ACPChangeNotifier {
    private let name: String
    // Dedicated serial queue for notify(3) delivery. Handlers may run
    // off the main thread — callers must hop to MainActor as needed.
    private let deliveryQueue = DispatchQueue(label: "io.alas.acp.notify")

    init(worktreeId: String, channel: String? = nil) {
        self.name = Self.channelName(worktreeId: worktreeId, channel: channel)
    }

    /// notify(3) names must be short, ASCII, and reverse-DNS-ish. Hash
    /// the (possibly long, space-containing) worktree id into a stable
    /// 64-bit suffix so any worktree maps to one safe channel.
    static func channelName(worktreeId: String, channel: String? = nil) -> String {
        var hash: UInt64 = 1469598103934665603   // FNV-1a offset basis
        for byte in worktreeId.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        let name = "io.alas.acp." + String(hash, radix: 16)
        return channel.map { name + "." + $0 } ?? name
    }

    func post() {
        notify_post(name)
    }

    func subscribe(_ handler: @escaping () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(name, &token, deliveryQueue) { _ in
            handler()
        }
        return token
    }

    func unsubscribe(_ token: Int32) {
        notify_cancel(token)
    }
}
