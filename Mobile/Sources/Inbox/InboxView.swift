import SwiftUI

/// Everything waiting on the user, answerable in place.
struct InboxView: View {
    let hub: HostHub
    @Environment(SessionRegistry.self) private var registry
    @State private var model = InboxModel()
    @State private var path: [SessionRoute] = []

    var body: some View {
        let entries = InboxModel.entries(in: hub)
        // An answered request leaves at once; the summary only catches up with the next list.
        let shown = entries.filter { entry in
            guard let session = model.sessions[entry.route], session.hasSnapshot else { return true }
            return session.hasPendingRequest
        }
        NavigationStack(path: $path) {
            Group {
                if shown.isEmpty {
                    ContentUnavailableView("Nothing needs you right now.", systemImage: "tray")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach(shown) { entry in section(entry) }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Inbox")
            .navigationDestination(for: SessionRoute.self) { route in
                TranscriptScreen(hostID: route.hostID, sessionId: route.sessionId)
            }
            .onChange(of: hub.hosts.map(\.id)) { _, ids in path.removeAll { !ids.contains($0.hostID) } }
        }
        .onAppear { model.sync(entries, registry: registry) }
        .onChange(of: entries) { _, new in model.sync(new, registry: registry) }
        .onDisappear { model.releaseAll() }
    }

    private func section(_ entry: InboxModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: entry.route) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(entry.hostName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            if let session = model.sessions[entry.route], session.hasPendingRequest {
                RequestCard(session: session)
            } else {
                Text("Waiting for the request…")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .modifier(CardSurface(floats: false))
            }
        }
    }
}
