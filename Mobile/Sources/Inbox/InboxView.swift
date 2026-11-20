import SwiftUI

/// Everything waiting on the user, answerable in place.
struct InboxView: View {
    let hub: HostHub
    let attention: AttentionFeed
    /// A route to push, set by a tapped notification; cleared once pushed.
    @Binding var openRoute: SessionRoute?
    @Environment(SessionRegistry.self) private var registry
    @State private var model = InboxModel()
    @State private var path: [SessionRoute] = []
    /// The session in the detail column, where there is room for one (iPad).
    @State private var selected: SessionRoute?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// A hidden tab keeps its view alive; it must not hold sessions then.
    @State private var visible = false
    /// Mac items whose whole body is showing.
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let entries = InboxModel.entries(in: hub)
        // An answered request leaves at once; the summary only catches up with the next list.
        let answeredHere = Set(model.sessions.filter { !$0.value.answered.isEmpty }.keys)
        // The rest stay, the badge counts them: a session can wait on a typed reply with no request.
        let shown = entries.filter { entry in
            guard let session = model.sessions[entry.route], session.hasSnapshot else { return true }
            return session.hasPendingRequest || !answeredHere.union(model.answered).contains(entry.route)
        }
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    list(shown)
                } detail: {
                    // Its own stack, for the diffs and files a session pushes.
                    NavigationStack {
                        if let selected {
                            TranscriptScreen(hostID: selected.hostID, sessionId: selected.sessionId).id(selected)
                        } else {
                            ContentUnavailableView("No session selected", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("Choose a request to see its session."))
                        }
                    }
                }
            } else {
                NavigationStack(path: $path) {
                    list(shown)
                        .navigationDestination(for: SessionRoute.self) { route in
                            TranscriptScreen(hostID: route.hostID, sessionId: route.sessionId)
                        }
                }
            }
        }
        .onChange(of: hub.hosts.map(\.id)) { _, ids in
            path.removeAll { !ids.contains($0.hostID) }
            if let selected, !ids.contains(selected.hostID) { self.selected = nil }
        }
        // Split View resizes swap the hierarchy; the open session moves with it.
        .onChange(of: sizeClass) { _, size in
            if size == .regular {
                if let open = path.last { selected = open }
                path = []
            } else if let open = selected {
                path = [open]
                selected = nil
            }
        }
        .onChange(of: openRoute, initial: true) { _, route in
            guard let route else { return }
            if sizeClass == .regular { selected = route } else { path = [route] }
            openRoute = nil
        }
        .onAppear {
            visible = true
            model.sync(entries, registry: registry)
            attention.refresh()
        }
        .onChange(of: entries) { _, new in
            model.answered.formIntersection(new.map(\.route))
            if visible { model.sync(new, registry: registry) }
        }
        .onChange(of: answeredHere) { _, routes in model.answered.formUnion(routes) }
        .onDisappear {
            visible = false
            model.releaseAll()
        }
    }

    private func list(_ shown: [InboxModel.Entry]) -> some View {
        Group {
            let items = attention.entries
            if shown.isEmpty, items.isEmpty {
                ContentUnavailableView("Nothing needs you right now", systemImage: "tray",
                                       description: Text("Permission requests, questions and plans from your sessions show up here, with run failures, conflicts and failed agents from your Macs."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(shown) { entry in section(entry) }
                        if !items.isEmpty {
                            Text("From your Macs").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            ForEach(items) { entry in attentionRow(entry) }
                        }
                    }
                    .padding(16)
                }
                .refreshable { attention.refresh() }
            }
        }
        .navigationTitle("Inbox")
    }

    private func open(_ route: SessionRoute) {
        if sizeClass == .regular {
            selected = route
        } else if path.last != route {
            path.append(route)
        }
    }

    private func section(_ entry: InboxModel.Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { open(entry.route) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Text(entry.hostName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, sizeClass == .regular ? 6 : 0)
                .background(selected == entry.route && sizeClass == .regular ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let session = model.sessions[entry.route], session.hasPendingRequest {
                RequestCard(session: session)
            } else if model.sessions[entry.route]?.hasSnapshot == true {
                CardChrome(icon: "text.bubble.fill", tint: .orange, kind: "Waiting", title: "The agent is waiting for your reply") {
                    CardButton(title: "Open Session", primary: true) { open(entry.route) }
                }
            } else {
                Text("Waiting for the request…")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .modifier(CardSurface(floats: false))
            }
        }
    }

    private func attentionRow(_ entry: AttentionFeed.Entry) -> some View {
        let item = entry.item
        let isExpanded = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                if let route = entry.route {
                    open(route)
                } else if isExpanded {
                    expanded.remove(item.id)
                } else {
                    expanded.insert(item.id)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: Self.symbol(item.kind)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).foregroundStyle(.primary).lineLimit(isExpanded ? nil : 2)
                        Text("\(item.project) · \(item.branch) · \(entry.hostName) · \(item.occurredAt, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let body = item.body, !body.isEmpty {
                            Text(body).font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 3)
                        }
                    }
                    Spacer(minLength: 0)
                    if entry.route != nil {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("Dismiss") {
                expanded.remove(item.id)
                attention.dismiss(entry)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(12)
        .modifier(CardSurface(floats: false))
    }

    private static func symbol(_ kind: String) -> String {
        switch kind {
        case "runScriptFailure": "exclamationmark.triangle"
        case "conflicts": "arrow.triangle.merge"
        case "agentFailed": "xmark.octagon"
        case "hostDisconnected": "wifi.slash"
        default: "bell"
        }
    }
}
