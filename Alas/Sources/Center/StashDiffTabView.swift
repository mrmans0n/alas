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

    private let git = GitService()

    var body: some View {
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
                    fileExtension: (state.file.path as NSString).pathExtension,
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
