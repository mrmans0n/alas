import SwiftUI

struct DiffTabView: View {
    let worktreePath: URL
    let relativePath: String
    @Environment(\.theme) var theme

    @State private var diff: ParsedDiff = ParsedDiff(hunks: [])
    @State private var totalAdd = 0
    @State private var totalDel = 0
    @State private var loaded = false
    @State private var error: String?

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
                            HunkView(hunk: hunk, language: SimpleHighlighter.language(forFile: relativePath))
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
        "\(worktreePath.path)\u{0}\(relativePath)"
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text((relativePath as NSString).lastPathComponent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.color("fg"))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((relativePath as NSString).deletingLastPathComponent)
                .font(.system(size: 11.5))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            HStack(spacing: 10) {
                Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                Text("−\(totalDel)").foregroundColor(theme.color("del"))
            }
            .font(.system(size: 11.5, design: .monospaced))
            HStack(spacing: 4) {
                AlasButton(title: "Stage hunk", style: .subtle, action: stageHunk)
                AlasButton(title: "Discard",    style: .subtle, action: discard)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private func load() async {
        loaded = false
        diff = ParsedDiff(hunks: [])
        totalAdd = 0
        totalDel = 0
        error = nil

        do {
            diff = try await git.diff(worktreePath: worktreePath, file: relativePath)
            totalAdd = diff.hunks.flatMap(\.lines).filter { $0.kind == .add }.count
            totalDel = diff.hunks.flatMap(\.lines).filter { $0.kind == .delete }.count
            loaded = true
        } catch {
            self.error = error.localizedDescription
            loaded = true
        }
    }

    private func stageHunk() {
        Task {
            guard let hunk = diff.hunks.first else { return }
            let patchLines = hunk.lines.map { line -> String in
                switch line.kind {
                case .add:     return "+\(line.text)"
                case .delete:  return "-\(line.text)"
                case .context: return " \(line.text)"
                }
            }
            // For untracked files the diff base is /dev/null; the patch header
            // must reflect that or `git apply --cached` rejects it with
            // "does not exist in index". For tracked files the conventional
            // a/<path> b/<path> headers work.
            let tracked = (try? await Process.git(
                ["ls-files", "--error-unmatch", "--", relativePath],
                cwd: worktreePath
            ))?.exitCode == 0
            let header: [String]
            if tracked {
                header = [
                    "diff --git a/\(relativePath) b/\(relativePath)",
                    "--- a/\(relativePath)",
                    "+++ b/\(relativePath)",
                    hunk.header,
                ]
            } else {
                header = [
                    "diff --git a/\(relativePath) b/\(relativePath)",
                    "new file mode 100644",
                    "--- /dev/null",
                    "+++ b/\(relativePath)",
                    hunk.header,
                ]
            }
            let patch = header.joined(separator: "\n") + "\n"
                + patchLines.joined(separator: "\n") + "\n"
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("alas-stage-\(UUID().uuidString).patch")
            try? patch.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try? await Process.git(["apply", "--cached", tmp.path], cwd: worktreePath)
            try? FileManager.default.removeItem(at: tmp)
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

private struct HunkView: View {
    let hunk: ParsedDiff.Hunk
    let language: String
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
                    HStack(spacing: 0) {
                        ForEach(Array(SimpleHighlighter.tokenize(line.text, language: language).enumerated()), id: \.offset) { (_, tok) in
                            Text(tok.text).foregroundColor(theme.color("fg"))
                        }
                    }
                    Spacer()
                }
                .font(.system(size: 12.5, design: .monospaced))
                .padding(.horizontal, 14)
                .background(rowBg(line))
            }
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
