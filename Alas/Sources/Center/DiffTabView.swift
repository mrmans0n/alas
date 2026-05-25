import SwiftUI

struct DiffTabView: View {
    let worktreePath: URL
    let relativePath: String
    let staged: Bool
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
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
    @State private var imagePair: ImageDiffPair?
    @State private var imagePairLoaded: Bool = false

    private let git = GitService()

    var body: some View {
        if ImageFileType.isSupported(relativePath: relativePath) {
            imageBody
        } else {
            textBody
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        Group {
            if !imagePairLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pair = imagePair {
                ImageDiffView(
                    pair: pair,
                    relativePath: relativePath,
                    onOpenFile: onOpenFile
                )
            } else {
                Text("Could not load image diff for \(relativePath)")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.color("bg-1"))
        .task(id: imageLoadKey) { await loadImagePair() }
    }

    private var imageLoadKey: String {
        "img:\(worktreePath.path)\u{0}\(relativePath)\u{0}\(staged)"
    }

    private func loadImagePair() async {
        imagePairLoaded = false
        imagePair = nil
        do {
            let pair = try await git.imageDiffPair(
                worktreePath: worktreePath,
                relativePath: relativePath,
                staged: staged
            )
            guard !Task.isCancelled else { return }
            imagePair = pair
        } catch {
            // Leave imagePair nil to show the error placeholder.
        }
        imagePairLoaded = true
    }

    @ViewBuilder
    private var textBody: some View {
        VStack(spacing: 0) {
            header
            if let error {
                Text(error)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
                    .foregroundColor(theme.color("del"))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color("bg-2"))
            }
            ScrollView(.vertical) {
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
                                codeFontFamily: codeFontFamily,
                                codeFontSize: codeFontSize,
                                onStage: actions.stage,
                                onDiscard: actions.discard
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .defaultScrollAnchor(.topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
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
                .font(.system(size: codeFontSize - 1.5))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            if shouldShowChangeSummary(additions: totalAdd, deletions: totalDel) {
                HStack(spacing: 10) {
                    Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                    Text("−\(totalDel)").foregroundColor(theme.color("del"))
                }
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 1.5))
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
            // Single off-main pass instead of two `.flatMap.filter.count`
            // allocations on MainActor — for big diffs each pass copies the
            // full line array, which would stall the UI right after parse.
            let (loadedTotalAdd, loadedTotalDel) = await Task.detached(priority: .userInitiated) {
                var add = 0
                var del = 0
                for hunk in loadedDiff.hunks {
                    for line in hunk.lines {
                        switch line.kind {
                        case .add: add += 1
                        case .delete: del += 1
                        case .context: break
                        }
                    }
                }
                return (add, del)
            }.value
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
            // For untracked files we need the real file mode so `git apply
            // --cached` doesn't drop the +x bit or rewrite a symlink as a
            // regular file. Tracked patches ignore this argument.
            let untrackedMode = Self.fileMode(at: worktreePath.appendingPathComponent(relativePath))
            let patch = HunkPatchBuilder.patch(
                file: relativePath,
                hunk: hunk,
                tracked: tracked,
                untrackedMode: untrackedMode
            )
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

    /// Map a worktree file to the git mode string used in a `new file mode`
    /// patch header. Symlinks → "120000", executable regular files → "100755",
    /// everything else → "100644". Falls back to "100644" when the file isn't
    /// readable (caller probably already errored out elsewhere).
    static func fileMode(at url: URL) -> String {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
                return "120000"
            }
            if let perms = attrs[.posixPermissions] as? NSNumber, perms.uintValue & 0o111 != 0 {
                return "100755"
            }
        } catch {
            // Fall through to default.
        }
        return HunkPatchBuilder.defaultUntrackedMode
    }
}

struct HunkView: View {
    let hunk: ParsedDiff.Hunk
    let fileExtension: String
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    var onStage:   (() -> Void)? = nil
    var onDiscard: (() -> Void)? = nil
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(hunk.header)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: headerFontSize))
                    .foregroundColor(theme.color("fg-dim"))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if onStage != nil {
                    AlasButton(title: "Stage hunk", style: .subtle, action: { onStage?() })
                }
                if onDiscard != nil {
                    AlasButton(title: "Discard hunk...", style: .subtle, action: { onDiscard?() })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
            .overlay(Divider().opacity(0.5), alignment: .top)
            .overlay(Divider().opacity(0.5), alignment: .bottom)
            DiffSelectableTextView(
                hunk: hunk,
                fileExtension: fileExtension,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                theme: theme
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The hunk header (@@…@@) is rendered slightly smaller than diff content.
    private var headerFontSize: CGFloat { (codeFontSize * 0.85).rounded() }
}
