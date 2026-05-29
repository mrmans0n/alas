import SwiftUI

struct ACPHistorySidebar: View {
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
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search chats\u{2026}", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
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
            HStack(spacing: 8) {
                if let agent = agentLookup(row.agentId) {
                    AgentLogoView(agent: agent).frame(width: 14, height: 14)
                }
                Text(row.title).lineLimit(1)
                Spacer()
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}
