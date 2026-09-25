import SwiftUI

struct NativePeerSessionRowPresentation {
    let detail: String

    init(row: RemoteSessionSummary) {
        let status = switch row.status {
        case "awaitingPermission": "Needs permission"
        case "awaitingInput": "Needs input"
        case "streaming": "Streaming"
        case "idle": "Idle"
        default: row.status
        }
        detail = [row.agentId, row.worktree?.worktreeName, status]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// App-scoped peer groups live beside the workspace tree, never inside a
/// worktree's Agents list.
struct NativePeerSidebarView: View {
    @Bindable var client: NativePeerSessions
    @State private var expandedPeerIDs: Set<String> = []

    var body: some View {
        if !client.snapshot.groups.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Peers")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)

                ForEach(client.snapshot.groups) { group in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedPeerIDs.contains(group.id) },
                        set: { expanded in
                            if expanded { expandedPeerIDs.insert(group.id) }
                            else { expandedPeerIDs.remove(group.id) }
                        }
                    )) {
                        if group.state.carriesSessions {
                            ForEach(group.sessions, id: \.id) { row in
                                let presentation = NativePeerSessionRowPresentation(row: row)
                                Button {
                                    client.select(row.id)
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: "bubble.left")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.title).lineLimit(1)
                                            Text(presentation.detail)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        if row.status == "awaitingPermission" || row.status == "awaitingInput" {
                                            Image(systemName: "exclamationmark.circle.fill")
                                                .foregroundStyle(.orange)
                                                .accessibilityLabel("Needs attention")
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(client.selectedSessionId == row.id
                                                ? Color.accentColor.opacity(0.18) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(row.title), \(presentation.detail), \(group.name) peer session")
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(group.state.carriesSessions ? .primary : .secondary)
                            Text(group.name).lineLimit(1)
                            Spacer(minLength: 4)
                            if group.attentionCount > 0 {
                                Text("\(group.attentionCount)")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .accessibilityLabel("\(group.attentionCount) need attention")
                            }
                            Text(group.state.label)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 5)
                    }
                    .accessibilityLabel("\(group.name), \(group.state.label)")
                }
            }
            .onAppear {
                expandedPeerIDs.formUnion(client.snapshot.groups.map(\.id))
            }
        }
    }
}
