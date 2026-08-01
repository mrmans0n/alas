import SwiftUI

enum MissionSpaceFilter {
    nonisolated static func isVisible(
        _ aggregate: MissionAggregate,
        activeProjectIds: Set<String>,
        existingProjectIds: Set<String>
    ) -> Bool {
        guard let projectId = aggregate.primaryLeg?.projectId else { return true }
        if !existingProjectIds.contains(projectId) { return true }
        return activeProjectIds.contains(projectId)
    }

    nonisolated static func isVisible(
        _ aggregate: MissionAggregate,
        activeProjectIds: [String],
        existingProjectIds: [String]
    ) -> Bool {
        isVisible(
            aggregate,
            activeProjectIds: Set(activeProjectIds),
            existingProjectIds: Set(existingProjectIds)
        )
    }
}

struct MissionSidebarModel: Equatable {
    var active: [MissionSidebarRow]
    var completed: [MissionSidebarRow]

    static var empty: MissionSidebarModel {
        .init(active: [], completed: [])
    }

    nonisolated static func make(
        aggregates: [MissionAggregate],
        activeProjectIds: [String],
        existingProjectIds: [String],
        knownWorktreeIds: Set<String>
    ) -> MissionSidebarModel {
        let activeProjects = Set(activeProjectIds)
        let existingProjects = Set(existingProjectIds)
        let visibleRows = aggregates
            .filter {
                MissionSpaceFilter.isVisible(
                    $0,
                    activeProjectIds: activeProjects,
                    existingProjectIds: existingProjects
                )
            }
            .map { MissionSidebarRow(aggregate: $0, knownWorktreeIds: knownWorktreeIds) }
            .sorted(by: sortRows)

        return .init(
            active: visibleRows.filter { !$0.isCompleted },
            completed: visibleRows.filter(\.isCompleted)
        )
    }

    private nonisolated static func sortRows(_ lhs: MissionSidebarRow, _ rhs: MissionSidebarRow) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

struct MissionSidebarRow: Equatable, Identifiable {
    enum Status: Equatable {
        case creating(String)
        case running
        case needsAttention
        case readyToComplete
        case completed

        var title: String {
            switch self {
            case .creating(let checkpoint):
                "Creating · \(checkpoint)"
            case .running:
                "Running"
            case .needsAttention:
                "Needs attention"
            case .readyToComplete:
                "Ready to complete"
            case .completed:
                "Completed"
            }
        }
    }

    let id: MissionID
    let title: String
    let providerAbbreviation: String
    let issueNumber: String
    let repositorySlug: String
    let updatedAt: Date
    let status: Status
    let isNavigationEnabled: Bool

    init(aggregate: MissionAggregate, knownWorktreeIds: Set<String> = []) {
        id = aggregate.mission.id
        title = aggregate.mission.title
        providerAbbreviation = aggregate.issue.identity.provider.missionSidebarAbbreviation
        issueNumber = "#\(aggregate.issue.identity.number)"
        repositorySlug = aggregate.issue.identity.repositorySlug
        updatedAt = aggregate.mission.updatedAt
        status = Self.status(for: aggregate.mission)

        if let worktreeId = aggregate.primaryLeg?.worktreeId {
            isNavigationEnabled = knownWorktreeIds.isEmpty || knownWorktreeIds.contains(worktreeId)
        } else {
            isNavigationEnabled = false
        }
    }

    var isCompleted: Bool {
        status == .completed
    }

    var helpText: String {
        let prefix = "\(providerAbbreviation) \(repositorySlug) \(issueNumber)"
        if isNavigationEnabled {
            return "\(prefix) · \(status.title)"
        }
        return "\(prefix) · Worktree is not available yet."
    }

    private static func status(for mission: MissionRecord) -> Status {
        switch mission.state {
        case .creating:
            .creating(mission.setupCheckpoint.sidebarTitle)
        case .running:
            .running
        case .needsAttention:
            .needsAttention
        case .readyToComplete:
            .readyToComplete
        case .completed:
            .completed
        }
    }
}

struct MissionSidebarSection: View {
    let model: MissionSidebarModel
    let selectedMissionID: MissionID?
    let onOpenMission: (MissionID) -> Void
    let onNewMission: () -> Void
    @Environment(\.theme) private var theme
    @State private var collapsed = false
    @State private var completedCollapsed = true
    @State private var hoveringHeader = false
    @State private var plusHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                VStack(spacing: 1) {
                    ForEach(model.active) { row in
                        MissionSidebarRowView(
                            row: row,
                            isSelected: selectedMissionID == row.id,
                            onOpenMission: onOpenMission
                        )
                    }
                    if !model.completed.isEmpty {
                        completedHeader
                        if !completedCollapsed {
                            ForEach(model.completed) { row in
                                MissionSidebarRowView(
                                    row: row,
                                    isSelected: selectedMissionID == row.id,
                                    onOpenMission: onOpenMission
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private var header: some View {
        Button {
            collapsed.toggle()
        } label: {
            HStack(spacing: 7) {
                Icon(name: collapsed ? "chev-right" : "chev-down", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
                Icon(name: "sparkle", size: 12, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
                Text("Missions")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            ZStack {
                Text("\(model.active.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("fg-faint"))
                    .monospacedDigit()
                    .opacity(hoveringHeader ? 0 : 1)
                    .allowsHitTesting(false)
                Button(action: onNewMission) {
                    Icon(
                        name: "plus",
                        size: 11,
                        color: plusHovering ? theme.color("fg") : theme.color("fg-faint")
                    )
                    .frame(width: 18, height: 18)
                    .background(plusHovering ? theme.color("bg-4") : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { plusHovering = $0 }
                .help("New Mission")
                .opacity(hoveringHeader ? 1 : 0)
                .allowsHitTesting(hoveringHeader)
            }
            .frame(width: 18, height: 18)
            .padding(.trailing, 12)
        }
        .onHover { hoveringHeader = $0 }
    }

    private var completedHeader: some View {
        Button {
            completedCollapsed.toggle()
        } label: {
            HStack(spacing: 7) {
                Icon(name: completedCollapsed ? "chev-right" : "chev-down", size: 9, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
                Text("Completed")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(theme.color("fg-faint"))
                Spacer(minLength: 0)
                Text("\(model.completed.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("fg-faint"))
                    .monospacedDigit()
            }
            .padding(.leading, 26)
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MissionSidebarRowView: View {
    let row: MissionSidebarRow
    let isSelected: Bool
    let onOpenMission: (MissionID) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            guard row.isNavigationEnabled else { return }
            onOpenMission(row.id)
        } label: {
            ZStack(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.color("bg-4"))
                    Rectangle()
                        .fill(theme.color("accent"))
                        .frame(width: 3, height: 14)
                        .clipShape(.rect(cornerRadius: 2))
                        .offset(x: 2, y: 0)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.providerAbbreviation)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundColor(theme.color("fg-muted"))
                        Text(row.issueNumber)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.color("fg-faint"))
                        Text(row.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.color(row.isNavigationEnabled ? "fg" : "fg-faint"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(row.status.title)
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.color("fg-faint"))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.leading, 32)
                .padding(.trailing, 10)
                .padding(.vertical, 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(row.isNavigationEnabled ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .disabled(!row.isNavigationEnabled)
        .help(row.helpText)
    }

    private var statusColor: Color {
        switch row.status {
        case .creating:
            theme.color("accent")
        case .running:
            theme.color("add")
        case .needsAttention:
            theme.color("warn")
        case .readyToComplete:
            theme.color("warning")
        case .completed:
            theme.color("fg-faint")
        }
    }
}

private extension CodeHostKind {
    var missionSidebarAbbreviation: String {
        switch self {
        case .github:
            "GH"
        case .gitlab:
            "GL"
        }
    }
}

private extension MissionSetupCheckpoint {
    var sidebarTitle: String {
        switch self {
        case .creatingWorktree:
            "Creating worktree"
        case .startingAgent:
            "Starting agent"
        case .running:
            "Running"
        }
    }
}
