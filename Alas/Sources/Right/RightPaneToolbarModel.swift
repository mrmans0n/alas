import Foundation

/// The trailing accessory of the right pane toolbar, which differs per tab.
enum RightPaneToolbarTrailing: Equatable {
    case none
    case diffTotals(add: Int, del: Int)
    case search
}

/// Derives the right pane toolbar's text and accessories from the active tab.
/// The toolbar replaces the panel title: the selected rail tab already names
/// the panel, so this row carries context instead.
enum RightPaneToolbarModel {
    static func leading(
        for tab: RightPaneTab,
        branch: String,
        activeAgentCount: Int,
        waitingAgentCount: Int,
        runningScriptNames: [String]
    ) -> String {
        switch tab {
        case .changes:
            return branch.isEmpty ? "Detached HEAD" : branch
        case .files:
            return "Working tree"
        case .agent:
            guard activeAgentCount > 0 else { return "No agents" }
            guard waitingAgentCount > 0 else { return "\(activeAgentCount) active" }
            return "\(activeAgentCount) active · \(waitingAgentCount) waiting"
        case .run:
            switch runningScriptNames.count {
            case 0:  return "Nothing running"
            case 1:  return runningScriptNames[0]
            default: return "\(runningScriptNames.count) running"
            }
        }
    }

    static func trailing(for tab: RightPaneTab, totalAdd: Int, totalDel: Int) -> RightPaneToolbarTrailing {
        switch tab {
        case .changes:
            return (totalAdd == 0 && totalDel == 0) ? .none : .diffTotals(add: totalAdd, del: totalDel)
        case .files:
            return .search
        case .agent, .run:
            return .none
        }
    }

    /// Only Files has anything to put in the overflow menu, and an empty menu
    /// is worse than no button.
    static func showsOverflowMenu(for tab: RightPaneTab) -> Bool {
        tab == .files
    }
}
