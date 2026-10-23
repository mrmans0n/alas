import Foundation

/// What Ship publishes of a gg stack: the entries up to
/// `shipThroughEntryID`, as one `gg sync --until`. The entry is named by
/// `GGStackEntry.id` (GG-ID, else SHA) and, without a GG-ID, also by its
/// title, so the plan survives the agent amending and rebasing the stack;
/// commits it adds above the boundary stay local.
public struct StackShipPlan: Codable, Equatable, Sendable {
    /// The topmost entry to publish; nil publishes the whole stack.
    public var shipThroughEntryID: String?
    /// The boundary's commit title when `shipThroughEntryID` is a SHA.
    /// Amending the entry, as `gg absorb` and `gg sc` do, changes the SHA
    /// but keeps the title, so a title only one entry has still finds it.
    public var shipThroughTitle: String?
    /// The requests this ship creates open as drafts (`gg sync --draft`).
    /// Entries that already have a request keep its state.
    public var opensDrafts: Bool

    public init(shipThroughEntryID: String? = nil, shipThroughTitle: String? = nil, opensDrafts: Bool = false) {
        self.shipThroughEntryID = shipThroughEntryID
        self.shipThroughTitle = shipThroughTitle
        self.opensDrafts = opensDrafts
    }

    /// Ships through the entry at `position` of `stack`, moved to where the
    /// line can stop (`linePositions`); the top entry, or one above it, ships
    /// the whole stack, so commits the agent adds on top ship too.
    public init(shipThroughPosition position: Int, of stack: GGStack, opensDrafts: Bool) {
        self.init(exactly: Self.snap(position, to: Self.linePositions(in: stack.entries)), of: stack, opensDrafts: opensDrafts)
    }

    /// Ships through the entry at `position` as it is, SHA-only or not: for
    /// a sync about to run, where no rewrite can come in between.
    private init(exactly position: Int, of stack: GGStack, opensDrafts: Bool) {
        let isTop = position >= (stack.entries.map(\.position).max() ?? 0)
        let entry = isTop ? nil : stack.entries.first { $0.position == position }
        self.init(
            shipThroughEntryID: entry?.id,
            shipThroughTitle: entry?.ggId == nil ? entry?.title : nil,
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
        guard let entry = boundary(in: stack) else {
            throw MissingEntry(entryID: shipThroughEntryID)
        }
        return max(entry.position, Self.highestPublishedPosition(in: stack))
    }

    /// The boundary entry: the one `shipThroughEntryID` names, else the only
    /// one titled `shipThroughTitle`. Two with that title name neither.
    private func boundary(in stack: GGStack) -> GGStackEntry? {
        if let entry = stack.entries.first(where: { $0.id == shipThroughEntryID }) { return entry }
        guard let shipThroughTitle else { return nil }
        let titled = stack.entries.filter { $0.title == shipThroughTitle }
        return titled.count == 1 ? titled.first : nil
    }

    /// The plan with its boundary on the entry it actually ships through, as
    /// `gg sync --until` needs it right before running. Not snapped: a raised
    /// boundary on a SHA-only published entry must not move up and publish
    /// a held-back one.
    public func resolved(in stack: GGStack) throws(MissingEntry) -> StackShipPlan {
        StackShipPlan(exactly: try shipThroughPosition(in: stack), of: stack, opensDrafts: opensDrafts)
    }

    /// What a stored plan ships once gg no longer lists its boundary, as
    /// after Clean removed the merged entries it shipped: the entries that
    /// already have a request, which is what `heldBackEntries` leaves out,
    /// so the whole stack once every entry has one. Nil when none has one.
    public func recovered(in stack: GGStack) -> StackShipPlan? {
        let through = Self.highestPublishedPosition(in: stack)
        guard through > 0 else { return nil }
        return StackShipPlan(exactly: through, of: stack, opensDrafts: opensDrafts)
    }

    /// The entries the plan leaves unpublished, bottom-up. A boundary gg no
    /// longer lists, as after Clean removes the merged entries it shipped,
    /// holds back every entry without a request.
    public func heldBackEntries(of stack: GGStack) -> [GGStackEntry] {
        let isHeldBack: (GGStackEntry) -> Bool
        if let through = try? shipThroughPosition(in: stack) {
            isHeldBack = { $0.position > through }
        } else {
            isHeldBack = { $0.prNumber == nil }
        }
        return stack.entries.filter(isHeldBack).sorted { $0.position < $1.position }
    }

    /// The lowest boundary Ship may use on `stack`: its highest entry with a
    /// request, 0 when none has one.
    public static func highestPublishedPosition(in stack: GGStack) -> Int {
        stack.entries.filter { $0.prNumber != nil }.map(\.position).max() ?? 0
    }

    /// Where Ship's line can stop among `entries`, ascending: the top, and
    /// every entry at or above the highest one with a request that the
    /// boundary can still name once the agent amends it: by GG-ID, else by
    /// a title no other entry has.
    public static func linePositions(in entries: [GGStackEntry]) -> [Int] {
        let top = entries.map(\.position).max() ?? 0
        let floor = entries.filter { $0.prNumber != nil }.map(\.position).max() ?? 0
        let titleCounts = Dictionary(entries.map { ($0.title, 1) }, uniquingKeysWith: +)
        let stops = entries.filter { entry in
            entry.position >= floor && (entry.ggId != nil || titleCounts[entry.title] == 1)
        }
        return Set(stops.map(\.position) + [top]).sorted()
    }

    /// `target` moved to the nearest stop at or below it, so a line that
    /// cannot stop where asked ships less; with none below, the lowest stop.
    public static func snap(_ target: Int, to stops: [Int]) -> Int {
        stops.last { $0 <= target } ?? stops.first ?? target
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
