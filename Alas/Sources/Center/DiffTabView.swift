import SwiftUI

struct DiffTabView: View {
    let worktreePath: URL
    let relativePath: String
    let staged: Bool
    let onOpenFile: (() -> Void)?
    @Environment(\.theme) var theme

    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var totalAdd = 0
    @State private var totalDel = 0
    @State private var loaded = false
    @State private var error: String?
    @State private var activeLoadKey: String?

    private let git = GitService()

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                if !loaded {
                    ProgressView().padding()
                } else if diff.hunks.isEmpty {
                    Text("No changes for \(relativePath)").foregroundColor(theme.color("fg-dim")).padding()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { (_, hunk) in
                            HunkView(hunk: hunk, fileExtension: (relativePath as NSString).pathExtension)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(theme.color("bg-1"))
        .task(id: loadKey) { await load() }
    }

    private var loadKey: String {
        "\(worktreePath.path)\u{0}\(relativePath)\u{0}\(staged)"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text((relativePath as NSString).lastPathComponent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.color("fg"))
            if staged {
                Text("STAGED")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.color("info").opacity(0.18))
                    .foregroundColor(theme.color("info"))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((relativePath as NSString).deletingLastPathComponent)
                .font(.system(size: 11.5))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            if shouldShowChangeSummary(additions: totalAdd, deletions: totalDel) {
                HStack(spacing: 10) {
                    Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                    Text("−\(totalDel)").foregroundColor(theme.color("del"))
                }
                .font(.system(size: 11.5, design: .monospaced))
            }
            HStack(spacing: 4) {
                if let onOpenFile {
                    AlasButton(title: "Open File", style: .subtle, action: onOpenFile)
                }
                if !staged, let first = diff.hunks.first {
                    AlasButton(title: "Stage hunk", style: .subtle, action: { stageHunk(first) })
                }
                AlasButton(title: "Discard", style: .subtle, action: discard)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private func load() async {
        let requestedLoadKey = loadKey
        activeLoadKey = requestedLoadKey
        loaded = false
        diff = ParsedDiff(hunks: [])
        totalAdd = 0
        totalDel = 0
        error = nil

        do {
            let loadedDiff = try await git.diff(worktreePath: worktreePath, file: relativePath, staged: staged)
            let loadedTotalAdd = loadedDiff.hunks.flatMap(\.lines).filter { $0.kind == .add }.count
            let loadedTotalDel = loadedDiff.hunks.flatMap(\.lines).filter { $0.kind == .delete }.count

            guard !Task.isCancelled, activeLoadKey == requestedLoadKey else { return }
            diff = loadedDiff
            totalAdd = loadedTotalAdd
            totalDel = loadedTotalDel
            loaded = true
        } catch {
            guard !Task.isCancelled, activeLoadKey == requestedLoadKey else { return }
            self.error = error.localizedDescription
            loaded = true
        }
    }

    private func stageHunk(_ hunk: ParsedDiff.Hunk) {
        Task {
            let tracked = (try? await Process.git(
                ["ls-files", "--error-unmatch", "--", relativePath],
                cwd: worktreePath
            ))?.exitCode == 0
            let patch = HunkPatchBuilder.patch(file: relativePath, hunk: hunk, tracked: tracked)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-stage-\(UUID().uuidString).patch")
            try? patch.write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                let result = try await Process.git(["apply", "--cached", tmp.path], cwd: worktreePath)
                if result.exitCode != 0 {
                    self.error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                self.error = (error as NSError).localizedDescription
            }
            await load()
        }
    }

    private func discard() {
        // `git checkout -- <path>` only restores a TRACKED file's worktree
        // copy from the index. It silently no-ops for untracked files (still
        // there) and doesn't unstage staged changes. Discard from the diff
        // view is opened from `git status --porcelain=v2` entries which
        // include both — handle each case explicitly:
        //
        //   tracked   → `git restore --staged --worktree --source=HEAD --` so
        //               both the index and the worktree go back to HEAD,
        //               covering staged-only, unstaged-only, and mixed states.
        //   untracked → `rm -f` since git won't touch it.
        Task {
            let tracked = (try? await Process.git(
                ["ls-files", "--error-unmatch", "--", relativePath],
                cwd: worktreePath
            ))?.exitCode == 0
            if tracked {
                _ = try? await Process.git(
                    ["restore", "--staged", "--worktree", "--source=HEAD", "--", relativePath],
                    cwd: worktreePath
                )
            } else {
                let absolute = worktreePath.appendingPathComponent(relativePath)
                try? FileManager.default.removeItem(at: absolute)
            }
            await load()
        }
    }
}

struct HunkView: View {
    let hunk: ParsedDiff.Hunk
    let fileExtension: String
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
                .padding(.horizontal, 14).padding(.vertical, 4)
                .background(theme.color("bg-2"))
                .overlay(Divider().opacity(0.5), alignment: .top)
                .overlay(Divider().opacity(0.5), alignment: .bottom)
            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { (_, line) in
                HStack(alignment: .top, spacing: 16) {
                    Text(lineMarker(line))
                        .frame(width: 44, alignment: .trailing)
                        .foregroundColor(markerColor(line))
                    Text(highlightedLine(line.text, ext: fileExtension))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.horizontal, 14)
                .background(rowBg(line))
            }
        }
    }

    /// Compose a single `AttributedString` for `line` with per-token
    /// foreground colors. Rendering as a single SwiftUI `Text` (rather
    /// than an HStack of per-token Texts) lets SwiftUI lay the line out
    /// as one run of text — without it, long lines collapse into a
    /// vertical stack of one-token columns under width pressure.
    private func highlightedLine(_ line: String, ext: String) -> AttributedString {
        var attr = AttributedString()
        for (text, capture) in renderedSpans(line, ext: ext) {
            var part = AttributedString(text)
            part.foregroundColor = color(for: capture)
            attr.append(part)
        }
        return attr
    }

    /// Build a sequence of `(text, capture)` pairs covering the entire
    /// `line`, using `TreeSitterHighlighter`'s per-line spans. Plain
    /// segments between captured ranges keep their text (capture = .plain).
    private func renderedSpans(_ line: String, ext: String) -> [(String, HighlightCapture)] {
        let ns = line as NSString
        let total = ns.length
        guard total > 0 else { return [] }
        let spans = TreeSitterHighlighter.tokenize(line: line, fileExtension: ext)
            .filter { $0.range.location >= 0 && NSMaxRange($0.range) <= total }
            .sorted { $0.range.location < $1.range.location }

        var result: [(String, HighlightCapture)] = []
        var cursor = 0
        for span in spans {
            if span.range.location < cursor { continue } // skip overlapping
            if span.range.location > cursor {
                let plainRange = NSRange(location: cursor, length: span.range.location - cursor)
                result.append((ns.substring(with: plainRange), .plain))
            }
            result.append((ns.substring(with: span.range), span.capture))
            cursor = NSMaxRange(span.range)
        }
        if cursor < total {
            let tail = NSRange(location: cursor, length: total - cursor)
            result.append((ns.substring(with: tail), .plain))
        }
        if result.isEmpty {
            result.append((line, .plain))
        }
        return result
    }

    private func color(for capture: HighlightCapture) -> Color {
        switch capture {
        case .keyword:  return theme.color("syntax-keyword")
        case .type:     return theme.color("syntax-type")
        case .function: return theme.color("syntax-function")
        case .string:   return theme.color("add")
        case .number:   return theme.color("mod")
        case .comment:  return theme.color("fg-faint")
        default:        return theme.color("fg")
        }
    }

    private func lineMarker(_ l: ParsedDiff.Hunk.Line) -> String {
        switch l.kind {
        case .add:     return "+\(l.newNumber.map(String.init) ?? "")"
        case .delete:  return "−\(l.oldNumber.map(String.init) ?? "")"
        case .context: return " \(l.oldNumber.map(String.init) ?? "")"
        }
    }

    private func rowBg(_ l: ParsedDiff.Hunk.Line) -> Color {
        switch l.kind {
        case .add:    return theme.color("add").opacity(0.10)
        case .delete: return theme.color("del").opacity(0.10)
        case .context: return .clear
        }
    }

    private func markerColor(_ l: ParsedDiff.Hunk.Line) -> Color {
        switch l.kind {
        case .add:    return theme.color("add")
        case .delete: return theme.color("del")
        case .context: return theme.color("fg-faint")
        }
    }
}
