import SwiftUI

struct CommitDiffView: View {
    let worktreePath: URL
    let sha: String
    let file: CommitChangedFile
    let path: String
    let diff: ParsedDiff
    let displayModel: DiffDisplayModel?
    let loading: Bool
    let error: String?
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let onOpenFile: (() -> Void)?
    let onDropHunk: ((ParsedDiff.Hunk) -> Void)?
    let dropHunkEnabled: (CommitChangedFile, ParsedDiff.Hunk) -> Bool

    @Environment(\.theme) private var theme
    @StateObject private var copyFeedback = CopyFeedbackState()
    @State private var titleHovering = false
    @State private var imagePair: ImageDiffPair?
    @State private var imagePairLoaded: Bool = false
    private let git = GitService()

    init(
        worktreePath: URL,
        sha: String,
        file: CommitChangedFile,
        path: String,
        diff: ParsedDiff,
        displayModel: DiffDisplayModel?,
        loading: Bool,
        error: String?,
        codeFontFamily: String = "",
        codeFontSize: CGFloat = 13,
        layoutMode: Binding<DiffLayoutMode>,
        wrapLines: Binding<Bool>,
        showWhitespace: Binding<Bool>,
        onOpenFile: (() -> Void)?,
        onDropHunk: ((ParsedDiff.Hunk) -> Void)? = nil,
        dropHunkEnabled: @escaping (CommitChangedFile, ParsedDiff.Hunk) -> Bool = { _, _ in false }
    ) {
        self.worktreePath = worktreePath
        self.sha = sha
        self.file = file
        self.path = path
        self.diff = diff
        self.displayModel = displayModel
        self.loading = loading
        self.error = error
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self._layoutMode = layoutMode
        self._wrapLines = wrapLines
        self._showWhitespace = showWhitespace
        self.onOpenFile = onOpenFile
        self.onDropHunk = onDropHunk
        self.dropHunkEnabled = dropHunkEnabled
    }

    var body: some View {
        if ImageFileType.isSupported(currentPath: path, originalPath: file.originalPath) {
            imageBody
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.color("bg-1"))
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        Group {
            if !imagePairLoaded {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pair = imagePair {
                ImageDiffView(
                    pair: pair,
                    relativePath: path,
                    onOpenFile: onOpenFile
                )
            } else {
                Text("Could not load image diff for \(path)")
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
        "img-commit:\(worktreePath.path)\u{0}\(sha)\u{0}\(path)"
    }

    private func loadImagePair() async {
        imagePairLoaded = false
        imagePair = nil
        do {
            let pair = try await git.imageDiffPairForCommit(
                worktreePath: worktreePath, sha: sha, file: file
            )
            guard !Task.isCancelled else { return }
            imagePair = pair
        } catch {
            // Leave imagePair nil; the placeholder shows the error path.
        }
        imagePairLoaded = true
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Text((path as NSString).lastPathComponent)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                    .foregroundColor(titleHovering ? theme.color("accent") : theme.color("fg"))
                Text("·").foregroundColor(theme.color("fg-faint"))
                Text((path as NSString).deletingLastPathComponent)
                    .font(.system(size: codeFontSize - 2))
                    .foregroundColor(titleHovering ? theme.color("accent") : theme.color("fg-dim"))
            }
            .contentShape(Rectangle())
            .onTapGesture { copyTitle() }
            .onHover { hovering in
                titleHovering = hovering
            }
            .pointingHandCursor()
            .help("Click to copy diff title")
            Spacer()
            if let onOpenFile {
                AlasButton(title: "Open File", style: .subtle, action: onOpenFile)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.4), alignment: .bottom)
        .copyFeedbackOverlay(message: copyFeedback.message)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            Spinner()
                .frame(width: 16, height: 16)
                .padding()
        } else if let error {
            Text("Could not load diff for \(path): \(error)")
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
                .foregroundColor(theme.color("del"))
                .padding()
        } else if diff.hunks.isEmpty {
            Text("No changes for \(path)")
                .foregroundColor(theme.color("fg-dim"))
                .padding()
        } else if let displayModel {
            DiffPaneView(
                model: displayModel,
                fileExtension: LanguageRegistry.highlighterExtension(forPath: path),
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsToolbar: false,
                verticalScrollMode: .internalScroll,
                lspContext: nil,
                allowsReviewLineSelection: false,
                hunkActions: { hunk in
                    DiffPaneHunkActions(
                        dropFromCommit: dropHunkEnabled(file, hunk) ? { onDropHunk?(hunk) } : nil
                    )
                }
            )
        } else {
            Spinner()
                .frame(width: 16, height: 16)
                .padding()
        }
    }

    private func copyTitle() {
        Clipboard.copy(path)
        copyFeedback.show("Copied title")
    }
}
