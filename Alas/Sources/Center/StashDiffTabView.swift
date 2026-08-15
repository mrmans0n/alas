import SwiftUI

struct StashDiffTabView: View {
    let worktreePath: URL
    let state: StashDiffTabState
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13

    @Environment(\.theme) private var theme
    @State private var loaded = false
    @State private var error: String?
    @State private var displayModel: DiffDisplayModel?
    @State private var layoutMode: DiffLayoutMode = .split
    @State private var wrapLines = false
    @State private var showWhitespace = false
    @State private var imagePair: ImageDiffPair?
    @State private var imagePairLoaded = false
    @State private var imageRetryGeneration = 0

    private let git = GitService()

    var body: some View {
        if ImageFileType.isSupported(currentPath: state.file.path, originalPath: state.file.oldPath) {
            imageBody
        } else {
            textBody
        }
    }

    @ViewBuilder
    private var imageBody: some View {
        Group {
            if !imagePairLoaded {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let imagePair {
                ImageDiffView(
                    pair: imagePair,
                    relativePath: state.file.path,
                    onOpenFile: nil,
                    sourceBadge: state.stash.ref,
                    onRetry: { imageRetryGeneration += 1 }
                )
            } else {
                Text("Could not load image diff for \(state.file.path)")
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
        "img-stash:\(worktreePath.path)\u{0}\(state.stash.sha)\u{0}\(state.file.path)\u{0}\(state.file.oldPath ?? "")\u{0}\(state.file.isUntracked)\u{0}\(imageRetryGeneration)"
    }

    private func loadImagePair() async {
        imagePairLoaded = false
        imagePair = nil
        do {
            let pair = try await git.imageDiffPairForStash(
                worktreePath: worktreePath,
                stash: state.stash,
                file: state.file
            )
            guard !Task.isCancelled else { return }
            imagePair = pair
        } catch {
            guard !Task.isCancelled else { return }
            // Leave imagePair nil; the placeholder shows the error path.
        }
        guard !Task.isCancelled else { return }
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.color("bg-2"))
            }
            if !loaded {
                Spinner()
                    .frame(width: 16, height: 16)
                    .padding()
            } else if let displayModel {
                DiffPaneView(
                    model: displayModel,
                    fileExtension: LanguageRegistry.highlighterExtension(forPath: state.file.path),
                    layoutMode: $layoutMode,
                    wrapLines: $wrapLines,
                    showWhitespace: $showWhitespace,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    allowsReviewLineSelection: false,
                    hunkActions: { _ in DiffPaneHunkActions() }
                )
            } else {
                Text("No changes for \(state.file.path)")
                    .foregroundColor(theme.color("fg-dim"))
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: "\(state.stash.ref)\u{0}\(state.file.path)") { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text((state.file.path as NSString).lastPathComponent)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))
            Text(state.stash.ref)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("accent").opacity(0.16))
                .foregroundColor(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((state.file.path as NSString).deletingLastPathComponent)
                .font(.system(size: codeFontSize - 1.5))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private func load() async {
        loaded = false
        error = nil
        displayModel = nil
        do {
            let diff = try await git.stashDiff(worktreePath: worktreePath, stash: state.stash, file: state.file)
            guard !Task.isCancelled else { return }
            let model = await Task.detached(priority: .userInitiated) {
                DiffDisplayModelBuilder.build(diff: diff, filePath: state.file.path)
            }.value
            guard !Task.isCancelled else { return }
            displayModel = diff.hunks.isEmpty ? nil : model
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            loaded = true
        }
    }
}
