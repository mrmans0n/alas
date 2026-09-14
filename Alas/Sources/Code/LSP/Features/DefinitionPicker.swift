import SwiftUI

/// Inline picker shown when LSP `textDocument/definition` returns more
/// than one location. The view is hosted in an `NSPopover` by the caller
/// and reports the chosen index (or nil for dismiss) through `onChoose`.
struct DefinitionPickerEntry: Identifiable, Equatable {
    let id = UUID()
    let displayPath: String   // e.g. "Foo.swift:42"
    let snippet: String       // single-line preview, may be empty
}

struct DefinitionPicker: View {
    let entries: [DefinitionPickerEntry]
    var snippetStore: EditorNavigationStore? = nil
    var snippetSessionID: UUID? = nil
    var targets: [EditorNavigationTarget] = []
    let onChoose: (Int?) -> Void

    @State private var selection: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(entries.count) DEFINITIONS")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        Button { onChoose(idx) } label: { row(idx: idx, entry: entry) }
                            .buttonStyle(.plain)
                            .background(idx == selection ? Color.accentColor.opacity(0.18) : Color.clear)
                            .contentShape(Rectangle())
                            .task { loadSnippet(at: idx) }
                            .onChange(of: snippetStore?.snippetRevision) { _, _ in loadSnippet(at: idx) }
                            .onDisappear {
                                if targets.indices.contains(idx), let snippetSessionID { snippetStore?.releaseSnippet(for: targets[idx], session: snippetSessionID) }
                            }
                    }
                }
            }
        }
        .frame(width: 380)
        .padding(.bottom, 6)
        .focusable()
        .onKeyPress(.upArrow)   { selection = max(0, selection - 1)
        return .handled }
        .onKeyPress(.downArrow) { selection = min(entries.count - 1, selection + 1)
        return .handled }
        .onKeyPress(.return)    { onChoose(selection)
        return .handled }
        .onKeyPress(.escape)    { onChoose(nil)
        return .handled }
    }

    private func row(idx: Int, entry: DefinitionPickerEntry) -> some View {
        let snippet = targets.indices.contains(idx) ? snippetStore?.snippets[targets[idx]] ?? entry.snippet : entry.snippet
        return VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayPath)
                .font(.system(size: 11, design: .monospaced))
            if !snippet.isEmpty {
                Text(snippet)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadSnippet(at index: Int) {
        guard targets.indices.contains(index), let snippetSessionID else { return }
        snippetStore?.loadSnippet(for: targets[index], session: snippetSessionID)
    }
}
