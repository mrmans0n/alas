import SwiftUI

enum MissionSpaceFilter {
    nonisolated static func isVisible(
        _ aggregate: MissionAggregate,
        activeProjectIds: Set<String>,
        existingProjectIds: Set<String>
    ) -> Bool {
        let legProjectIDs = Set(aggregate.legs.map(\.projectId))
        guard !legProjectIDs.isEmpty else { return true }
        let allLegProjectsMissing = legProjectIDs.isDisjoint(with: existingProjectIds)
        return allLegProjectsMissing || !legProjectIDs.isDisjoint(with: activeProjectIds)
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
    enum Tone: Equatable {
        case progress
        case success
        case attention
        case ready
        case muted
    }

    enum Status: Equatable {
        case creating(String)
        case aggregate(String)
        case running
        case needsAttention
        case readyToComplete
        case completed

        var title: String {
            switch self {
            case .creating(let checkpoint):
                "Creating · \(checkpoint)"
            case .aggregate(let summary):
                summary
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
    let providerName: String
    let providerIconName: String
    let sourceReference: String?
    let issueNumber: String
    let repositorySlug: String
    let updatedAt: Date
    let status: Status
    let tone: Tone
    let isNavigationEnabled: Bool

    init(aggregate: MissionAggregate, knownWorktreeIds _: Set<String> = []) {
        id = aggregate.mission.id
        title = aggregate.mission.title
        providerName = aggregate.source.providerLabel
        providerIconName = aggregate.source.repositoryLocator?.provider.iconName ?? "link"
        sourceReference = aggregate.source.displayReference
        issueNumber = aggregate.source.displayReference ?? ""
        repositorySlug = aggregate.source.repositoryLocator?.repositorySlug ?? ""
        updatedAt = aggregate.mission.updatedAt
        status = Self.status(for: aggregate)
        tone = Self.tone(for: aggregate)

        isNavigationEnabled = true
    }

    var isCompleted: Bool {
        status == .completed
    }

    var helpText: String {
        let prefix = [providerName, repositorySlug.isEmpty ? nil : repositorySlug, sourceReference]
            .compactMap { $0 }
            .joined(separator: " ")
        if isNavigationEnabled {
            return "\(prefix) · \(status.title)"
        }
        return "\(prefix) · Open Mission details."
    }

    private static func status(for aggregate: MissionAggregate) -> Status {
        switch aggregate.mission.state {
        case .creating:
            .creating(aggregate.mission.setupCheckpoint.sidebarTitle)
        case .running:
            .aggregate(MissionAggregateSummary.statusCopy(for: aggregate.legs))
        case .needsAttention:
            .aggregate(MissionAggregateSummary.statusCopy(for: aggregate.legs))
        case .readyToComplete:
            .readyToComplete
        case .completed:
            .completed
        }
    }

    private static func tone(for aggregate: MissionAggregate) -> Tone {
        if aggregate.mission.state == .completed {
            return .muted
        }
        if aggregate.legs.contains(where: { $0.state == .needsAttention }) {
            return .attention
        }
        switch aggregate.mission.state {
        case .creating:
            return .progress
        case .running:
            return .success
        case .needsAttention:
            return .attention
        case .readyToComplete:
            return .ready
        case .completed:
            return .muted
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
                        Icon(name: row.providerIconName, size: 11, color: theme.color("fg-muted"))
                            .frame(width: 13, height: 13)
                            .accessibilityLabel(row.providerName)
                        if let sourceReference = row.sourceReference {
                            Text(sourceReference)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundColor(theme.color("fg-faint"))
                        }
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
        switch row.tone {
        case .progress:
            theme.color("accent")
        case .success:
            theme.color("add")
        case .attention:
            theme.color("warn")
        case .ready:
            theme.color("warning")
        case .muted:
            theme.color("fg-faint")
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
