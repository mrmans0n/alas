import SwiftUI

struct DiffTabView: View {
    let worktreePath: URL
    let relativePath: String
    let staged: Bool
    let onOpenFile: (() -> Void)?
    let onRequestDiscardFile: (() -> Void)?
    @Environment(\.theme) var theme

    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var totalAdd = 0
    @State private var totalDel = 0
    @State private var loaded = false
    @State private var error: String?
    @State private var activeLoadKey: String?
    @State private var confirmingDiscardHunk: ParsedDiff.Hunk? = nil
    @State private var isFileTracked: Bool = true
    @State private var isFileDeleted: Bool = false

    private let git = GitService()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("del"))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color("bg-2"))
            }
            ScrollView {
                if !loaded {
                    ProgressView().padding()
                } else if diff.hunks.isEmpty {
                    Text("No changes for \(relativePath)").foregroundColor(theme.color("fg-dim")).padding()
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.hunks.enumerated()), id: \.offset) { (_, hunk) in
                            let actions = stagedHunkActions(hunk: hunk)
                            HunkView(
                                hunk: hunk,
                                fileExtension: (relativePath as NSString).pathExtension,
                                onStage: actions.stage,
                                onDiscard: actions.discard
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(theme.color("bg-1"))
        .task(id: loadKey) { await load() }
        .alert(
            "Discard this hunk in \u{201C}\((relativePath as NSString).lastPathComponent)\u{201D}?",
            isPresented: Binding(
                get: { confirmingDiscardHunk != nil },
                set: { if !$0 { confirmingDiscardHunk = nil } }
            ),
            actions: {
                Button("Discard", role: .destructive) {
                    if let h = confirmingDiscardHunk {
                        confirmingDiscardHunk = nil
                        performDiscardHunk(h)
                    }
                }
                Button("Cancel", role: .cancel) { confirmingDiscardHunk = nil }
            },
            message: {
                Text("This permanently removes the selected hunk from your working copy. This cannot be undone.")
            }
        )
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
                if let onRequestDiscardFile {
                    AlasButton(title: "Discard Changes...", style: .subtle, action: onRequestDiscardFile)
                }
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
            let tracked = (try? await Process.git(
                ["ls-files", "--error-unmatch", "--", relativePath],
                cwd: worktreePath
            ))?.exitCode == 0
            // A tracked file that's gone from disk is an unstaged deletion.
            // The diff for it has `+++ /dev/null`, so reverse-applying a
            // per-hunk patch (which uses `+++ b/<path>`) would fail — hide
            // Discard hunk in that case and rely on file-level Discard.
            let deleted = tracked && !FileManager.default.fileExists(
                atPath: worktreePath.appendingPathComponent(relativePath).path
            )

            guard !Task.isCancelled, activeLoadKey == requestedLoadKey else { return }
            diff = loadedDiff
            totalAdd = loadedTotalAdd
            totalDel = loadedTotalDel
            isFileTracked = tracked
            isFileDeleted = deleted
            loaded = true
        } catch {
            guard !Task.isCancelled, activeLoadKey == requestedLoadKey else { return }
            self.error = error.localizedDescription
            loaded = true
        }
    }

    private func stageHunk(_ hunk: ParsedDiff.Hunk) {
        Task {
            let tracked = isFileTracked
            let patch = HunkPatchBuilder.patch(file: relativePath, hunk: hunk, tracked: tracked)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-stage-\(UUID().uuidString).patch")
            defer { try? FileManager.default.removeItem(at: tmp) }
            var didFail = false
            do {
                try patch.write(to: tmp, atomically: true, encoding: .utf8)
                let result = try await Process.git(["apply", "--cached", tmp.path], cwd: worktreePath)
                if result.exitCode != 0 {
                    self.error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    didFail = true
                }
            } catch {
                self.error = (error as NSError).localizedDescription
                didFail = true
            }
            // Only reload on success — load() resets `error` at its start, so
            // calling it after a failure would erase the error we just set
            // and make the action look like a silent no-op.
            if !didFail { await load() }
        }
    }

    private func stagedHunkActions(hunk: ParsedDiff.Hunk) -> (stage: (() -> Void)?, discard: (() -> Void)?) {
        // Staged view: no per-hunk actions for now (out of scope).
        if staged { return (nil, nil) }
        // Unstaged tracked, file exists: stage + discard.
        // Unstaged untracked: stage only (Discard hidden — whole file IS the hunk).
        // Unstaged tracked, file deleted: stage only (Discard hidden — the
        // generated patch would have `+++ b/<path>` but reverse-apply needs
        // /dev/null; file-level Discard restores the whole file).
        let stage: () -> Void = { stageHunk(hunk) }
        let discard: (() -> Void)? = (isFileTracked && !isFileDeleted)
            ? { confirmingDiscardHunk = hunk }
            : nil
        return (stage, discard)
    }

    private func performDiscardHunk(_ hunk: ParsedDiff.Hunk) {
        Task {
            let patch = HunkPatchBuilder.patch(file: relativePath, hunk: hunk, tracked: true)
            var didFail = false
            do {
                try await git.applyPatchReverse(worktreePath: worktreePath, patch: patch)
            } catch {
                self.error = (error as NSError).localizedDescription
                didFail = true
            }
            // See stageHunk: load() clears `error`, so only reload on success.
            if !didFail { await load() }
        }
    }
}

struct HunkView: View {
    let hunk: ParsedDiff.Hunk
    let fileExtension: String
    var onStage:   (() -> Void)? = nil
    var onDiscard: (() -> Void)? = nil
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(hunk.header)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                Spacer(minLength: 8)
                if onStage != nil {
                    AlasButton(title: "Stage hunk", style: .subtle, action: { onStage?() })
                }
                if onDiscard != nil {
                    AlasButton(title: "Discard hunk...", style: .subtle, action: { onDiscard?() })
                }
            }
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
