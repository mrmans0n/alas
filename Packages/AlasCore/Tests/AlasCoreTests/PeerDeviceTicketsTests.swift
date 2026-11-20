import Foundation
import Testing
@testable import AlasHostCore

@MainActor
struct PeerDeviceTicketsTests {
    @Test func ticketsAreSingleUseAndExpireAtTheirDeadline() {
        let tickets = PeerDeviceTickets()
        let attachment = PeerDeviceTickets.Binding(linkID: UUID(), attachmentID: UUID(), pairingID: "phone", deviceID: UUID())

        let first = tickets.issue(for: attachment, now: .zero)
        #expect(first.utf8.count == 43)
        #expect(tickets.redeem(first, now: .seconds(1)) == attachment)
        #expect(tickets.redeem(first, now: .seconds(1)) == nil)

        let second = tickets.issue(for: attachment, now: .seconds(1))
        #expect(tickets.redeem(second, now: .seconds(16)) == nil)
    }

    @Test func invalidatingOneLinkDoesNotInvalidateAReplacementForTheSamePairing() {
        let tickets = PeerDeviceTickets()
        let old = PeerDeviceTickets.Binding(linkID: UUID(), attachmentID: UUID(), pairingID: "phone", deviceID: UUID())
        let replacement = PeerDeviceTickets.Binding(linkID: UUID(), attachmentID: old.attachmentID, pairingID: old.pairingID, deviceID: old.deviceID)
        let oldTicket = tickets.issue(for: old, now: .zero)
        let replacementTicket = tickets.issue(for: replacement, now: .zero)

        tickets.invalidate(linkID: old.linkID)
        #expect(tickets.redeem(oldTicket, now: .seconds(1)) == nil)
        #expect(tickets.redeem(replacementTicket, now: .seconds(1)) == replacement)
    }
}
