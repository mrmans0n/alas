import Foundation

/// What Ship publishes of a gg stack: the entries up to
/// `shipThroughEntryID`, as one `gg sync --until`. The entry is named by
/// `GGStackEntry.id` (GG-ID, else SHA), so the plan survives the agent
/// amending and rebasing the stack; commits it adds above the boundary stay
/// local.
public struct StackShipPlan: Codable, Equatable, Sendable {
    /// The topmost entry to publish; nil publishes the whole stack.
    public var shipThroughEntryID: String?
    /// The requests this ship creates open as drafts (`gg sync --draft`).
    /// Entries that already have a request keep its state.
    public var opensDrafts: Bool

    public init(shipThroughEntryID: String? = nil, opensDrafts: Bool = false) {
        self.shipThroughEntryID = shipThroughEntryID
        self.opensDrafts = opensDrafts
    }

    /// Ships through the entry at `position` of `stack`, or the highest one
    /// that already has a request; the top entry, or one above it, ships the
    /// whole stack, so commits the agent adds on top ship too.
    public init(shipThroughPosition position: Int, of stack: GGStack, opensDrafts: Bool) {
        let through = max(position, Self.highestPublishedPosition(in: stack))
        let isTop = through >= (stack.entries.map(\.position).max() ?? 0)
        self.init(
            shipThroughEntryID: isTop ? nil : stack.entries.first { $0.position == through }?.id,
            opensDrafts: opensDrafts
        )
    }

    public static let wholeStack = StackShipPlan()

    /// The boundary is no longer in the stack.
    public struct MissingEntry: Error, Equatable, Sendable {
        public let entryID: String
    }

    /// The position of the topmost entry the plan publishes: the boundary's,
    /// else the top of the stack. Never below an entry that already has a
    /// request: `gg sync` cannot take one back, and its fixes must still be
    /// pushed.
    public func shipThroughPosition(in stack: GGStack) throws(MissingEntry) -> Int {
        guard let shipThroughEntryID else { return stack.entries.map(\.position).max() ?? 0 }
        guard let entry = stack.entries.first(where: { $0.id == shipThroughEntryID }) else {
            throw MissingEntry(entryID: shipThroughEntryID)
        }
        return max(entry.position, Self.highestPublishedPosition(in: stack))
    }

    /// The plan with its boundary on the entry it actually ships through, as
    /// `gg sync --until` needs it.
    public func resolved(in stack: GGStack) throws(MissingEntry) -> StackShipPlan {
        StackShipPlan(shipThroughPosition: try shipThroughPosition(in: stack), of: stack, opensDrafts: opensDrafts)
    }

    /// The entries the plan leaves unpublished, bottom-up.
    public func heldBackEntries(of stack: GGStack) throws(MissingEntry) -> [GGStackEntry] {
        let through = try shipThroughPosition(in: stack)
        return stack.entries.filter { $0.position > through }.sorted { $0.position < $1.position }
    }

    /// The lowest boundary Ship may use on `stack`: its highest entry with a
    /// request, 0 when none has one.
    public static func highestPublishedPosition(in stack: GGStack) -> Int {
        stack.entries.filter { $0.prNumber != nil }.map(\.position).max() ?? 0
    }
}

/// A Ship popover choice waiting for the session's `stack_ship`. Saved with
/// the shepherd records, so a relaunch before the agent publishes keeps it.
public struct PendingStackShip: Codable, Equatable, Sendable {
    public let sessionID: String
    public let id: StackShepherdRecordID
    public let plan: StackShipPlan
    public let chosenAt: Date

    public init(sessionID: String, id: StackShepherdRecordID, plan: StackShipPlan, chosenAt: Date) {
        self.sessionID = sessionID
        self.id = id
        self.plan = plan
        self.chosenAt = chosenAt
    }
}
