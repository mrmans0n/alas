import SwiftUI
import AppKit

/// SwiftUI fuzzy file picker for the composer's @-mention popover.
/// Hosted inside an NSPanel (see `ACPMentionPickerPanel`) so it can float
/// above the chat with proper key forwarding.
struct ACPMentionPickerView: View {
    let worktreeRoot: URL
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @State private var query: String = ""
    @State private var highlight: Int = 0
    @FocusState private var searchFocused: Bool
    @State private var allFiles: [URL] = []

    private var ranked: [URL] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return Array(allFiles.prefix(80))
        }
        return MentionFuzzy.rank(files: allFiles, query: q, limit: 80)
    }

    var body: some View {
        VStack(spacing: 0) {
            search
            Divider().background(theme.color("line"))
            list
        }
        .frame(width: 360, height: 280)
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
        .onAppear { populateFiles() }
        .onKeyPress { press in handleKey(press) }
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "at")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            TextField("Search files in worktree…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .onChange(of: query) { _, _ in highlight = 0 }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if ranked.isEmpty {
                        Text(allFiles.isEmpty ? "Indexing worktree…" : "No matches")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                            .padding(.horizontal, 10).padding(.vertical, 10)
                    } else {
                        ForEach(Array(ranked.enumerated()), id: \.element) { idx, file in
                            row(idx: idx, file: file).id(idx)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: highlight) { _, new in
                proxy.scrollTo(new, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func row(idx: Int, file: URL) -> some View {
        let isOn = idx == highlight
        let name = file.lastPathComponent
        let rel = file.path.replacingOccurrences(of: worktreeRoot.path + "/", with: "")
        let parent = (rel as NSString).deletingLastPathComponent

        Button { onPick(file) } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(isOn ? theme.color("accent") : theme.color("fg-faint"))
                    .frame(width: 14)
                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.color("fg"))
                if !parent.isEmpty {
                    Text(parent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(isOn ? theme.color("accent").opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlight = idx }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let count = ranked.count
        switch press.key {
        case .escape:
            onCancel()
            return .handled
        case .upArrow:
            highlight = max(0, highlight - 1); return .handled
        case .downArrow:
            highlight = min(max(0, count - 1), highlight + 1); return .handled
        case .return:
            if ranked.indices.contains(highlight) { onPick(ranked[highlight]) }
            return .handled
        default:
            return .ignored
        }
    }

    private func populateFiles() {
        // Walk the worktree in the background and post results once.
        let root = worktreeRoot
        Task.detached(priority: .userInitiated) {
            let result = MentionFuzzy.collectFiles(under: root, limit: 5000)
            await MainActor.run { allFiles = result }
        }
    }
}

// MARK: - Fuzzy matching

enum MentionFuzzy {
    /// Walk the worktree, returning regular files (skipping .git, build,
    /// node_modules, DerivedData, etc.) up to `limit`. Sorted by basename
    /// for stable empty-query display.
    static func collectFiles(under root: URL, limit: Int) -> [URL] {
        var out: [URL] = []
        let skipDirs: Set<String> = [
            ".git", "node_modules", ".build", "build", "DerivedData", ".alas",
            ".next", "dist", "out", "target", ".venv", "venv", ".tox", ".cache",
            "__pycache__", ".idea", ".vscode", ".superpowers",
        ]
        guard let it = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: []
        ) else { return [] }

        for case let url as URL in it {
            if out.count >= limit { break }
            let name = url.lastPathComponent
            if skipDirs.contains(name) {
                it.skipDescendants()
                continue
            }
            if name.hasPrefix(".") {
                it.skipDescendants()
                continue
            }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            out.append(url)
        }
        out.sort { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        return out
    }

    /// Rank files for a query. Score blends:
    ///   - basename prefix match (highest)
    ///   - basename subsequence (chars in order)
    ///   - path substring
    /// Higher score = better match. Ties broken by shorter relative path.
    static func rank(files: [URL], query: String, limit: Int) -> [URL] {
        let q = query.lowercased()
        var scored: [(URL, Int)] = []
        for f in files {
            let name = f.lastPathComponent.lowercased()
            let path = f.path.lowercased()
            var score = 0
            if name.hasPrefix(q) {
                score = 1000 - name.count
            } else if name.contains(q) {
                score = 500 - name.count
            } else if path.contains(q) {
                score = 200
            } else if let sub = subsequenceScore(in: name, query: q) {
                score = 300 - (name.count - q.count) - sub
            } else if let sub = subsequenceScore(in: path, query: q) {
                score = 100 - sub
            } else {
                continue
            }
            scored.append((f, score))
        }
        scored.sort { ($0.1, -$0.0.path.count) > ($1.1, -$1.0.path.count) }
        return Array(scored.prefix(limit).map(\.0))
    }

    /// Returns the sum of inter-match gaps for a fuzzy subsequence match,
    /// or nil if `query`'s chars don't appear in `haystack` in order.
    /// Lower = tighter match.
    private static func subsequenceScore(in haystack: String, query: String) -> Int? {
        var gap = 0, total = 0
        var qIdx = query.startIndex
        var lastMatch: String.Index?
        for i in haystack.indices {
            if qIdx == query.endIndex { break }
            if haystack[i] == query[qIdx] {
                if let last = lastMatch {
                    gap = haystack.distance(from: last, to: i) - 1
                    total += gap
                }
                lastMatch = i
                qIdx = query.index(after: qIdx)
            }
        }
        return qIdx == query.endIndex ? total : nil
    }
}
