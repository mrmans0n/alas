import SwiftUI

/// A worktree-owned, lazily-rendered references surface. The store is held by
/// `TabsManager`, so this view is intentionally disposable.
struct EditorNavigationResultsView: View {
    @Environment(\.designScale) private var scale
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
                    .fill(theme.color("line"))
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
        HStack(spacing: scale.space[2]) {
            Button {
                store.isExpanded.toggle()
            } label: {
                Image(systemName: store.isExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isExpanded ? "Collapse references" : "Expand references")
            Text("References")
                .font(scale.meta.font(weight: .semibold))
            Text("\(store.results.count)")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-muted"))
                .accessibilityLabel("\(store.results.count) references")
            if store.resultsAreStale {
                Text("Stale")
                    .font(scale.meta.font(weight: .medium))
                    .foregroundStyle(theme.color("warn"))
                    .accessibilityLabel("Reference results are stale")
                Button("Rerun", action: onRerun)
                    .buttonStyle(.plain)
                    .font(scale.metaFont)
                    .accessibilityLabel("Rerun reference search")
            }
            if store.isLoading { Button("Cancel") { store.cancelRequest() }.buttonStyle(.plain) }
            if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("warn"))
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
        .padding(.horizontal, scale.space[2])
        .frame(height: 30)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            ProgressView("Finding references…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage {
            Text(error)
                .foregroundStyle(theme.color("del"))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if store.results.isEmpty {
            Text("No references found")
                .foregroundStyle(theme.color("fg-muted"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: scale.space[0]) {
                    ForEach(grouped, id: \.document) { group in
                        Text(documentLabel(group.document))
                            .font(scale.meta.font(weight: .medium))
                            .foregroundStyle(theme.color("fg-muted"))
                            .padding(.top, scale.space[1])
                        ForEach(group.targets, id: \.self) { target in
                            Button {
                                store.selectedResult = target
                                onOpen(target)
                            } label: {
                                VStack(alignment: .leading, spacing: scale.space[0]) {
                                    Text("Line \(target.position.line + 1)")
                                        .font(scale.meta.font(weight: .medium))
                                    Text(store.snippets[target] ?? "Loading snippet…")
                                        .font(scale.meta.font(design: .monospaced))
                                        .lineLimit(1)
                                        .foregroundStyle(theme.color("fg-muted"))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, scale.space[3])
                            .padding(.vertical, scale.space[1])
                            .background(store.selectedResult == target ? Color.accentColor.opacity(0.15) : .clear)
                            .accessibilityAddTraits(store.selectedResult == target ? .isSelected : [])
                            .accessibilityLabel("Open \(target.document.uri), line \(target.position.line + 1)")
                            .task { store.loadSnippet(for: target) }
                            .onChange(of: store.snippetRevision) { _, _ in store.loadSnippet(for: target) }
                            .onDisappear { store.releaseSnippet(for: target) }
                        }
                    }
                }
                .padding(.horizontal, scale.space[2])
                .padding(.bottom, scale.space[2])
            }
            .focusable()
            .onKeyPress(.downArrow) { store.moveResultSelection(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) { store.moveResultSelection(by: -1)
                return .handled
            }
            .onKeyPress(.return) {
                guard let target = store.selectedResult else { return .ignored }
                onOpen(target)
                return .handled
            }
        }
    }

    private var grouped: [(document: EditorDocumentID, targets: [EditorNavigationTarget])] {
        store.groupedResults
            .map { (document: $0.key, targets: $0.value.sorted {
                $0.position.line == $1.position.line ? $0.position.character < $1.position.character : $0.position.line < $1.position.line
            }) }
            .sorted {
                $0.document.uri == $1.document.uri ? ($0.document.host ?? "") < ($1.document.host ?? "") : $0.document.uri < $1.document.uri
            }
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
