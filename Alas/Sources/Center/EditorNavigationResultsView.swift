import SwiftUI

/// A worktree-owned, lazily-rendered references surface. The store is held by
/// `TabsManager`, so this view is intentionally disposable.
struct EditorNavigationResultsView: View {
    let store: EditorNavigationStore
    let onOpen: (EditorNavigationTarget) -> Void
    let onRerun: () -> Void
    let onReturnFocus: () -> Void
    @Environment(\.theme) private var theme
    @State private var dragStartHeight: CGFloat?

    var body: some View {
        if store.isPresented {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(theme.color("border"))
                    .frame(height: 1)
                    .gesture(resizeGesture)
                header
                if store.isExpanded {
                    content
                }
            }
            .frame(height: store.isExpanded ? store.height : nil)
            .background(theme.color("bg-1"))
            .onKeyPress(.escape) {
                onReturnFocus()
                return .handled
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                store.isExpanded.toggle()
            } label: {
                Image(systemName: store.isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isExpanded ? "Collapse references" : "Expand references")
            Text("References")
                .font(.system(size: 12, weight: .semibold))
            Text("\(store.results.count)")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-muted"))
                .accessibilityLabel("\(store.results.count) references")
            if store.resultsAreStale {
                Text("Stale")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("warning"))
                    .accessibilityLabel("Reference results are stale")
                Button("Rerun", action: onRerun)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityLabel("Rerun reference search")
            }
            if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("warning"))
                    .lineLimit(1)
            }
            Spacer()
            Button {
                store.close()
                onReturnFocus()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close references")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            ProgressView("Finding references…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            Text(error)
                .foregroundStyle(theme.color("red"))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if store.results.isEmpty {
            Text("No references found")
                .foregroundStyle(theme.color("fg-muted"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(grouped, id: \.document) { group in
                        Text(documentLabel(group.document))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.color("fg-muted"))
                            .padding(.top, 5)
                        ForEach(group.targets, id: \.self) { target in
                            Button {
                                onOpen(target)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Line \(target.position.line + 1)")
                                        .font(.system(size: 11, weight: .medium))
                                    Text(store.snippets[target] ?? "Loading snippet…")
                                        .font(.system(size: 11, design: .monospaced))
                                        .lineLimit(1)
                                        .foregroundStyle(theme.color("fg-muted"))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 3)
                            .accessibilityLabel("Open \(target.document.uri), line \(target.position.line + 1)")
                            .task { store.loadSnippet(for: target) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
        }
    }

    private var grouped: [(document: EditorDocumentID, targets: [EditorNavigationTarget])] {
        store.groupedResults
            .map { (document: $0.key, targets: $0.value.sorted { $0.position.line < $1.position.line }) }
            .sorted { $0.document.uri < $1.document.uri }
    }

    private func documentLabel(_ document: EditorDocumentID) -> String {
        guard let host = document.host else { return document.uri }
        return "\(host): \(document.uri)"
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartHeight == nil { dragStartHeight = store.height }
                store.height = max(100, min(500, (dragStartHeight ?? store.height) - value.translation.height))
            }
            .onEnded { _ in dragStartHeight = nil }
    }
}
