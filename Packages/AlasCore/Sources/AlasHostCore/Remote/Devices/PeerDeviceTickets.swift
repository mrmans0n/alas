import Crypto
import Foundation
import AlasFoundation

/// Main-actor ticket book. A consumed ticket stays consumed even if its
/// attachment is no longer authorized when the upgrade reaches the host.
@MainActor
final class PeerDeviceTickets {
    struct Binding: Equatable {
        let linkID: UUID
        let attachmentID: UUID
        let pairingID: String
        let deviceID: PeerDeviceID
    }

    static let lifetime: Duration = .seconds(15)

    private struct Entry {
        let binding: Binding
        let deadline: Duration
    }

    private var pending: [String: Entry] = [:]

    func issue(for binding: Binding, now: Duration) -> String {
        invalidate(binding)
        let ticket = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        pending[ticket] = Entry(binding: binding, deadline: now + Self.lifetime)
        return ticket
    }

    func redeem(_ ticket: String, now: Duration) -> Binding? {
        guard ticket.utf8.count == 43, let entry = pending.removeValue(forKey: ticket), now < entry.deadline else { return nil }
        return entry.binding
    }

    func invalidate(linkID: UUID) {
        pending = pending.filter { $0.value.binding.linkID != linkID }
    }

    func invalidate(_ binding: Binding) {
        if let ticket = pending.first(where: { $0.value.binding == binding })?.key {
            pending.removeValue(forKey: ticket)
        }
    }
}
