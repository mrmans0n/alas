import SwiftUI

struct ACPHistorySidebar: View {
    @ObservedObject var manager: ACPSessionManager
    let agentLookup: (String) -> AgentDefinition?
    @State private var search: String = ""

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
    }

    private var filtered: [ACPSessionRow] {
        guard !search.isEmpty else { return manager.recent }
        return manager.recent.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func rowView(_ row: ACPSessionRow) -> some View {
        Button {
            _ = manager.placeholderSession(id: row.id)
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
