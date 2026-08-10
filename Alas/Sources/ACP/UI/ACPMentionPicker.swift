import SwiftUI
import AppKit

/// SwiftUI fuzzy file picker for the composer's @-mention popover.
/// Hosted inside an NSPanel (see `ACPMentionPickerPanel`) so it can float
/// above the chat with proper key forwarding.
struct ACPMentionPickerView: View {
    let worktreeRoot: URL
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    let filesProvider: (@Sendable () async -> [URL])?

    @Environment(\.theme) private var theme
    @State private var query: String = ""
    @State private var highlight: Int = 0
    @FocusState private var searchFocused: Bool
    @State private var allFiles: [URL] = []
    @State private var ranked: [URL] = []
    @State private var isIndexing: Bool = true
    @State private var rankTask: Task<Void, Never>?
    @State private var rankGeneration: Int = 0
    @State private var scrollOnHighlightChange = false

    private let maxDisplay = 80

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
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "at")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color("accent"))
            TextField("Search files & folders…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($searchFocused)
                .onAppear { searchFocused = true }
                .onKeyPress { press in handleKey(press) }
                .onChange(of: query) { _, _ in
                    scrollOnHighlightChange = false
                    highlight = 0
                    rescheduleRank()
                }
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
                        Text(isIndexing ? "Indexing worktree…" : "No matches")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                            .padding(.horizontal, 10).padding(.vertical, 10)
                    } else {
                        ForEach(Array(ranked.enumerated()), id: \.element) { idx, file in
                            // Data-based id (the file URL), not the row
                            // position: a positional id freezes LazyVStack rows
                            // against the ranked list changing as you type.
                            row(idx: idx, file: file).id(file)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: highlight) { _, new in
                guard scrollOnHighlightChange else { return }
                scrollOnHighlightChange = false
                guard ranked.indices.contains(new) else { return }
                proxy.scrollTo(ranked[new], anchor: .center)
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
                Image(systemName: file.hasDirectoryPath ? "folder" : "doc.text")
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
            if hovering {
                scrollOnHighlightChange = false
                highlight = idx
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            onCancel()
            return .handled
        case .upArrow:
            moveHighlight(by: -1)
            return .handled
        case .downArrow:
            moveHighlight(by: 1)
            return .handled
        case .return, .tab:
            if ranked.indices.contains(highlight) { onPick(ranked[highlight]) }
            return .handled
        default:
            return .ignored
        }
    }

    private func moveHighlight(by offset: Int) {
        let next = MentionPickerNavigation.move(from: highlight, by: offset, count: ranked.count)
        guard next != highlight else { return }
        scrollOnHighlightChange = true
        highlight = next
    }

    private func populateFiles() {
        Task { @MainActor in
            isIndexing = true
            let files: [URL]
            if let provider = filesProvider {
                files = await provider()
            } else {
                let root = worktreeRoot
                files = await Task.detached(priority: .userInitiated) {
                    MentionFuzzy.collectFiles(under: root, limit: 5000)
                }.value
            }
            allFiles = MentionFuzzy.deduplicated(files: files, relativeTo: worktreeRoot)
            isIndexing = false
            rescheduleRank()
        }
    }

    private func rescheduleRank() {
        rankTask?.cancel()
        rankGeneration &+= 1
        let gen = rankGeneration
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = allFiles
        let root = worktreeRoot
        rankTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: 16_000_000)
            if Task.isCancelled { return }
            let result: [URL]
            if q.isEmpty {
                result = Array(files.prefix(maxDisplay))
            } else {
                result = MentionFuzzy.rank(files: files, query: q, limit: maxDisplay, relativeTo: root)
            }
            if Task.isCancelled { return }
            await MainActor.run {
                if rankGeneration == gen { ranked = result }
            }
        }
    }
}

enum MentionPickerNavigation {
    static func move(from index: Int, by offset: Int, count: Int) -> Int {
        min(max(0, count - 1), max(0, index + offset))
    }
}

// MARK: - Fuzzy matching

enum MentionFuzzy {
    static func deduplicated(files: [URL], relativeTo root: URL) -> [URL] {
        var result: [URL] = []
        var indices: [String: Int] = [:]
        for file in files {
            let path = relativePath(for: file, root: root)
            if let index = indices[path] {
                if file.hasDirectoryPath { result[index] = file }
            } else {
                indices[path] = result.count
                result.append(file)
            }
        }
        return result
    }

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
            // Directories are pickable too — the enumerator yields them with
            // `hasDirectoryPath` set, which the picker uses to show a folder
            // icon and to emit a directory resource link. We still recurse into
            // them (no `skipDescendants`) so their files remain available.
            out.append(url)
        }
        out.sort { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
        return out
    }

    /// Derive every directory implied by a set of worktree-relative paths, as
    /// directory-flagged URLs under `root`. `git ls-files` only emits files
    /// (collapsing untracked directories to a trailing-slash entry), so tracked
    /// directories never appear on their own — we reconstruct the full set from
    /// each path's ancestors. A trailing slash marks the whole path as a
    /// directory; otherwise the last component is a file and is dropped.
    static func ancestorDirectories(forRelativePaths paths: [String], root: URL) -> [URL] {
        var seen = Set<String>()
        var ordered: [String] = []
        for path in paths {
            let isDirEntry = path.hasSuffix("/")
            let comps = path.split(separator: "/").map(String.init)
            let dirCount = isDirEntry ? comps.count : comps.count - 1
            guard dirCount > 0 else { continue }
            for end in 1...dirCount {
                let dir = comps[0..<end].joined(separator: "/")
                if seen.insert(dir).inserted { ordered.append(dir) }
            }
        }
        return ordered.map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// Directory URLs to add to the picker for a `git ls-files`-style listing.
    /// The caller resolves each entry's on-disk directory-ness: untracked
    /// directories arrive collapsed with git's trailing slash, but submodule
    /// gitlinks arrive like a file path (no slash). Normalizing directory
    /// entries to a trailing slash lets `ancestorDirectories` emit the entry
    /// itself — not just its parent — so submodule folders stay pickable.
    static func pickerDirectories(forEntries entries: [(path: String, isDirectory: Bool)], root: URL) -> [URL] {
        let normalized = entries.map { entry -> String in
            entry.isDirectory && !entry.path.hasSuffix("/") ? entry.path + "/" : entry.path
        }
        return ancestorDirectories(forRelativePaths: normalized, root: root)
    }

    static func rank(files: [URL], query: String, limit: Int, relativeTo root: URL) -> [URL] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return Array(files.prefix(limit)) }

        let normalizedQuery = query.lowercased()
        var scored: [(url: URL, pathPriority: Int, score: Double, relativePath: String)] = []
        for f in files {
            let relativePath = relativePath(for: f, root: root)
            guard let score = score(file: f, relativePath: relativePath, tokens: tokens) else {
                continue
            }
            let normalizedPath = relativePath.lowercased()
            let pathPriority = normalizedPath == normalizedQuery ? 3
                : normalizedPath.hasPrefix(normalizedQuery) ? 2
                : normalizedPath.contains(normalizedQuery) ? 1
                : 0
            scored.append((f, pathPriority, score, relativePath))
        }
        scored.sort {
            if $0.pathPriority != $1.pathPriority { return $0.pathPriority > $1.pathPriority }
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.relativePath.count != $1.relativePath.count {
                return $0.relativePath.count < $1.relativePath.count
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return Array(scored.prefix(limit).map(\.url))
    }

    private static func score(file: URL, relativePath: String, tokens: [String]) -> Double? {
        var total = 0.0
        for token in tokens {
            let nameScore = FuzzyMatch.score(query: token, target: file.lastPathComponent)?
                .score
                .advanced(by: 8)
            let pathScore = FuzzyMatch.score(query: token, target: relativePath)?.score
            guard let best = [nameScore, pathScore].compactMap(\.self).max() else {
                return nil
            }
            total += best
        }
        return total - Double(relativePath.count) * 0.001
    }

    private static func relativePath(for file: URL, root: URL) -> String {
        let commonRoot = root.standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let prefix = commonRoot.hasSuffix("/") ? commonRoot : commonRoot + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
