import Foundation

public enum VMSlotDecision: Equatable, Sendable {
    case start
    case alreadyRunningHere
    case runningElsewhere(label: String)
    /// Record ids of every running macOS VM, least recently used first.
    case needsUserChoice(candidates: [String])
}

/// macOS licensing allows two concurrent macOS guests per host; other guests
/// take no slot. Records are expected to come from `WorktreeVMRegistry`, which
/// already cleared dead owners.
public enum VMSlotPolicy {
    public static let macOSSlots = 2

    public static func decide(
        requesting: String, records: [WorktreeVMRecord], me: VMRunOwner
    ) -> VMSlotDecision {
        if let owner = records.first(where: { $0.id == requesting })?.runOwner {
            return owner.isSameProcess(as: me) ? .alreadyRunningHere : .runningElsewhere(label: owner.label)
        }
        guard VMIdentity.parse(recordID: requesting).guest == .macOS else { return .start }
        let running = records.filter { $0.guestOS == .macOS && $0.runOwner != nil }
        guard running.count >= macOSSlots else { return .start }
        return .needsUserChoice(candidates: running.sorted { $0.lastUsedAt < $1.lastUsedAt }.map(\.id))
    }
}
