import SwiftUI

struct ACPHistorySidebar: View {
    @Environment(\.designScale) private var scale
    @ObservedObject var manager: ACPSessionManager
    let agentLookup: (String) -> AgentDefinition?
    @State private var search: String = ""
    /// Ids materialized through this sidebar's row taps. We retain on
    /// materialization so the placeholder doesn't sit forever in the
    /// manager dict, then release everything en masse when the sidebar
    /// goes away — letting any id NOT independently retained by another
    /// surface (e.g. the active tab) get evicted.
    @State private var retainedIds: Set<ACPSession.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[1]) {
            TextField("Search chats\u{2026}", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(scale.space[2])
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scale.space[0]) {
                    ForEach(filtered, id: \.id) { row in
                        rowView(row)
                    }
                }
            }
        }
        .onDisappear {
            for id in retainedIds {
                manager.releaseSession(id: id)
            }
            retainedIds.removeAll()
        }
    }

    private var filtered: [ACPSessionRow] {
        guard !search.isEmpty else { return manager.recent }
        return manager.recent.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func rowView(_ row: ACPSessionRow) -> some View {
        Button {
            if manager.placeholderSession(id: row.id) != nil,
               retainedIds.insert(row.id).inserted {
                manager.retainSession(id: row.id)
            }
        } label: {
            HStack(spacing: scale.space[2]) {
                if let agent = agentLookup(row.agentId) {
                    AgentLogoView(agent: agent).frame(width: 14, height: 14)
                }
                Text(row.title).lineLimit(1)
                Spacer()
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, scale.space[2]).padding(.vertical, scale.space[1])
    }
}
