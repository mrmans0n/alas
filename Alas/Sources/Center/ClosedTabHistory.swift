import Foundation

enum ClosedTabSnapshot: Equatable {
    case worktree(worktreeID: String, tab: Tab)

    var tabID: TabID {
        switch self {
        case .worktree(_, let tab): tab.id
        }
    }

    var worktreeID: String? {
        guard case .worktree(let worktreeID, _) = self else { return nil }
        return worktreeID
    }
}

struct ClosedTabPlacement: Equatable {
    let previousID: TabID?
    let nextID: TabID?
    let ordinal: Int

    init(tabID: TabID, orderedIDs: [TabID]) {
        guard let index = orderedIDs.firstIndex(of: tabID) else {
            previousID = nil
            nextID = nil
            ordinal = orderedIDs.count
            return
        }
        previousID = index > orderedIDs.startIndex ? orderedIDs[index - 1] : nil
        nextID = orderedIDs.indices.contains(index + 1) ? orderedIDs[index + 1] : nil
        ordinal = index
    }

    init(previousID: TabID?, nextID: TabID?, ordinal: Int) {
        self.previousID = previousID
        self.nextID = nextID
        self.ordinal = ordinal
    }

    func insertionIndex(in currentIDs: [TabID]) -> Int {
        if let nextID, let index = currentIDs.firstIndex(of: nextID) { return index }
        if let previousID, let index = currentIDs.firstIndex(of: previousID) { return index + 1 }
        return min(max(ordinal, 0), currentIDs.count)
    }
}

struct ClosedTabEntry: Identifiable, Equatable {
    let id: UUID
    let snapshot: ClosedTabSnapshot
    let placement: ClosedTabPlacement

    init(id: UUID = UUID(), snapshot: ClosedTabSnapshot, placement: ClosedTabPlacement) {
        self.id = id
        self.snapshot = snapshot
        self.placement = placement
    }
}

struct ClosedTabHistory: Equatable {
    static let capacity = 50

    private(set) var entries: [ClosedTabEntry] = []

    var last: ClosedTabEntry? { entries.last }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    mutating func record(_ entry: ClosedTabEntry) {
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    mutating func record(contentsOf newEntries: [ClosedTabEntry]) {
        for entry in newEntries { record(entry) }
    }

    mutating func remove(id: ClosedTabEntry.ID) {
        entries.removeAll { $0.id == id }
    }

    mutating func purge(worktreeID: String) {
        entries.removeAll { $0.snapshot.worktreeID == worktreeID }
    }

}

extension PaneNode {
    func replacingLeaves(using replacements: [String: PaneLeaf]) -> PaneNode {
        switch self {
        case .leaf(let leaf):
            return replacements[leaf.id].map(PaneNode.leaf) ?? self
        case .split(var split):
            split.children = split.children.map { $0.replacingLeaves(using: replacements) }
            return .split(split)
        }
    }
}
