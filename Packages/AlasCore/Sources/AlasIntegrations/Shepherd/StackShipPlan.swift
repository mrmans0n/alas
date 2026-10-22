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

    /// Ships through the entry at `position` of `stack`; the top entry, or
    /// one above it, ships the whole stack, so commits the agent adds on top
    /// ship too.
    public init(shipThroughPosition position: Int, of stack: GGStack, opensDrafts: Bool) {
        let isTop = position >= (stack.entries.map(\.position).max() ?? 0)
        self.init(
            shipThroughEntryID: isTop ? nil : stack.entries.first { $0.position == position }?.id,
            opensDrafts: opensDrafts
        )
    }

    public static let wholeStack = StackShipPlan()

    /// The boundary is no longer in the stack.
    public struct MissingEntry: Error, Equatable, Sendable {
        public let entryID: String
    }

    /// The position of the topmost entry the plan publishes: the boundary's,
    /// else the top of the stack.
    public func shipThroughPosition(in stack: GGStack) throws(MissingEntry) -> Int {
        guard let shipThroughEntryID else { return stack.entries.map(\.position).max() ?? 0 }
        guard let entry = stack.entries.first(where: { $0.id == shipThroughEntryID }) else {
            throw MissingEntry(entryID: shipThroughEntryID)
        }
        return entry.position
    }

    /// The entries the plan leaves unpublished, bottom-up.
    public func heldBackEntries(of stack: GGStack) throws(MissingEntry) -> [GGStackEntry] {
        let through = try shipThroughPosition(in: stack)
        return stack.entries.filter { $0.position > through }.sorted { $0.position < $1.position }
    }
}

/// A Ship popover choice waiting for the session's `stack_ship`.
public struct PendingStackShip: Equatable, Sendable {
    public let id: StackShepherdRecordID
    public let plan: StackShipPlan

    public init(id: StackShepherdRecordID, plan: StackShipPlan) {
        self.id = id
        self.plan = plan
    }
}
