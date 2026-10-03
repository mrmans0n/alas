import Foundation

/// Transient sidebar filter over worktree title, name, and branch. It only narrows
/// what the sidebar renders; worktree visibility and order are never mutated,
/// so the active sort mode still applies and clearing restores the full tree.
enum WorktreeSidebarFilter {
    static func isActive(_ query: String) -> Bool {
        !normalized(query).isEmpty
    }

    static func matches(_ worktree: Worktree, query: String) -> Bool {
        let query = normalized(query)
        return [worktree.title, worktree.branch, worktree.name].contains {
            FuzzyMatch.score(query: query, target: $0) != nil
        }
    }

    /// Keeps the input order, so callers pass lists already in sort order.
    static func apply(_ query: String, to worktrees: [Worktree]) -> [Worktree] {
        guard isActive(query) else { return worktrees }
        return worktrees.filter { matches($0, query: query) }
    }

    /// Arrow-key cursor over the matched worktrees in display order. Clamps at
    /// both ends; with no current match, down starts at the top and up at the
    /// bottom.
    static func moveHighlight(from current: String?, by offset: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return offset >= 0 ? ids.first : ids.last
        }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// Magnetic filter-row slot: a scroll landing partway through it finishes
    /// fully open or fully hidden, leaning hidden past the halfway point.
    static func snappedOffset(_ offset: CGFloat, slot: CGFloat) -> CGFloat {
        guard offset > 0, offset < slot else { return offset }
        return offset < slot / 2 ? 0 : slot
    }

    /// Readiness comes from one scroll-layout snapshot. The separate viewport
    /// measurement used to pad short lists can arrive after an overflowing
    /// list's only layout callback.
    static func initialParkingOffset(contentHeight: CGFloat, viewportHeight: CGFloat, slot: CGFloat) -> CGFloat? {
        guard viewportHeight > 0, contentHeight >= viewportHeight + slot else { return nil }
        return slot
    }

    /// Where the filter row draws, from the top of the scroll area. Unpinned
    /// it rides its slot at the top of the content and scrolls away with it;
    /// pinned it never rises above its rest position, but still follows a pull
    /// past the top.
    static func rowY(scrollOffset: CGFloat, pinned: Bool, restY: CGFloat) -> CGFloat {
        let natural = restY - scrollOffset
        return pinned ? max(natural, restY) : natural
    }

    /// Fades the row out as it slides above the scroll area.
    static func rowOpacity(y: CGFloat, height: CGFloat) -> Double {
        Double(min(1, max(0, (y + height) / height)))
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces)
    }
}
