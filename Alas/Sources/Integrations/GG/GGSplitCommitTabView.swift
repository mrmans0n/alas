import SwiftUI

struct GGSplitCommitTabView: View {
    let tabState: GGSplitCommitTabState
    let worktreePath: URL
    let capabilities: GGCapabilities
    let workflowAvailable: Bool
    let hasBlockingGitOperation: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let onCancel: () -> Void
    let onDraftChange: (GGSplitCommitDraft) -> Void

    @Environment(\.theme) private var theme
    @State private var model: GGSplitCommitModel
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var errorMessage: String?
    @State private var layoutMode: DiffLayoutMode = .stacked
    @State private var wrapLines = false
    @State private var showWhitespace = false

    init(
        tabState: GGSplitCommitTabState,
        worktreePath: URL,
        rightPaneState: RightPaneState,
        capabilities: GGCapabilities,
        workflowAvailable: Bool,
        hasBlockingGitOperation: Bool,
        initialDraft: GGSplitCommitDraft?,
        codeFontFamily: String,
        codeFontSize: CGFloat,
        onCancel: @escaping () -> Void,
        onDraftChange: @escaping (GGSplitCommitDraft) -> Void
    ) {
        self.tabState = tabState
        self.worktreePath = worktreePath
        self.capabilities = capabilities
        self.workflowAvailable = workflowAvailable
        self.hasBlockingGitOperation = hasBlockingGitOperation
        self.codeFontFamily = codeFontFamily
        self.codeFontSize = codeFontSize
        self.onCancel = onCancel
        self.onDraftChange = onDraftChange
        _model = State(initialValue: GGSplitCommitModel(
            service: rightPaneState,
            target: GGSplitCommitTarget(
                worktreeId: tabState.worktreeId,
                targetGGID: tabState.targetGGID,
                targetSHA: tabState.targetSHA
            ),
            capabilities: capabilities,
            workflowAvailable: workflowAvailable && !hasBlockingGitOperation,
            initialDraft: initialDraft
        ))
    }

    var body: some View {
        Group {
            switch tabState.presentation(
                capabilities: capabilities,
                workflowAvailable: workflowAvailable,
                hasBlockingGitOperation: hasBlockingGitOperation
            ) {
            case .unavailable(let reason):
                unavailableView(reason: reason)
            case .available:
                availableContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
        .task(id: tabState.id) { await load() }
    }

    private var availableContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isLoading {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.description == nil {
                loadFailure
            } else {
                HStack(spacing: 0) {
                    selectionPane
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                    Divider()
                    editorAndPreviews
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.trianglehead.branch")
                .foregroundStyle(theme.color("accent"))
            VStack(alignment: .leading, spacing: 2) {
                Text("Split Commit")
                    .font(.headline)
                Text(tabState.targetGGID ?? tabState.targetSHA)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 2)))
                    .foregroundStyle(theme.color("fg-dim"))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            if !isLoading {
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await load() }
                }
                .disabled(isApplying)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
    }

    private var selectionPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hunks")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.fileGroups) { group in
                        splitFileGroup(group)
                    }
                }
            }
        }
        .background(theme.color("bg-2"))
    }

    private func splitFileGroup(_ group: GGSplitCommitFileGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: group.kind == .selectable ? "doc.text" : "doc")
                    .foregroundStyle(theme.color("fg-dim"))
                Text(group.path)
                    .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if group.kind == .remainderOnly {
                    Text("Remainder only")
                        .font(.caption)
                        .foregroundStyle(theme.color("fg-dim"))
                }
            }

            ForEach(group.hunks, id: \.id) { hunk in
                Toggle(
                    isOn: Binding(
                        get: { model.selectedHunkIDs.contains(hunk.id) },
                        set: { _ in
                            model.toggleHunk(hunk.id)
                            errorMessage = nil
                            onDraftChange(model.draft)
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hunk.header)
                            .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                            .foregroundStyle(theme.color("fg"))
                        Text(hunk.patch)
                            .font(CenterTypography.codeFont(family: codeFontFamily, size: max(9, codeFontSize - 2)))
                            .foregroundStyle(theme.color("fg-dim"))
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(12)
        .overlay(Divider(), alignment: .bottom)
    }

    private var editorAndPreviews: some View {
        VStack(spacing: 0) {
            messageEditor
            Divider()
            VSplitView {
                previewPane(title: "First commit", preview: model.firstPreview)
                    .frame(minHeight: 180)
                previewPane(
                    title: "Remainder",
                    preview: model.remainderPreview,
                    showsResultingImages: true
                )
                    .frame(minHeight: 180)
            }
            Divider()
            actionBar
        }
    }

    private var messageEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("First commit")
                    .foregroundStyle(theme.color("fg-dim"))
                TextField("Commit message", text: $model.firstMessage)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.firstMessage) {
                        errorMessage = nil
                        onDraftChange(model.draft)
                    }
            }
            GridRow {
                Text("Remainder")
                    .foregroundStyle(theme.color("fg-dim"))
                TextField("Commit message", text: $model.remainderMessage)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: model.remainderMessage) {
                        errorMessage = nil
                        onDraftChange(model.draft)
                    }
            }
        }
        .padding(12)
        .background(theme.color("bg-2"))
    }

    private func previewPane(
        title: String,
        preview: GGSplitPreview,
        showsResultingImages: Bool = false
    ) -> some View {
        let partition = GGResultingImagePreview.partition(preview.nonTextualFiles)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(preview.files.flatMap(\.hunkIDs).count) hunk\(preview.files.flatMap(\.hunkIDs).count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-dim"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.color("bg-2"))
            Divider()
            if preview.files.isEmpty && preview.nonTextualFiles.isEmpty {
                Text("No content assigned")
                    .foregroundStyle(theme.color("fg-dim"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(preview.files) { file in
                            splitPreviewFile(file)
                        }
                        if showsResultingImages, let targetSHA = model.targetSHA {
                            ForEach(partition.imagePaths, id: \.self) { path in
                                GGSplitResultingImagePreview(
                                    path: path,
                                    worktreePath: worktreePath,
                                    revision: targetSHA,
                                    codeFontFamily: codeFontFamily,
                                    codeFontSize: codeFontSize
                                )
                            }
                        }
                        ForEach(partition.otherPaths, id: \.self) { path in
                            Label(path, systemImage: "doc")
                                .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                                .foregroundStyle(theme.color("fg-dim"))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func splitPreviewFile(_ file: GGSplitPreviewFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(file.path)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                .foregroundStyle(theme.color("fg"))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("bg-2"))
            DiffPaneView(
                model: DiffDisplayModelBuilder.build(diff: file.diff, filePath: file.path),
                fileExtension: LanguageRegistry.highlighterExtension(forPath: file.path),
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsToolbar: false,
                verticalScrollMode: .staticHeight,
                lspContext: nil,
                allowsReviewLineSelection: false,
                hunkActions: { _ in DiffPaneHunkActions() }
            )
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let message = errorMessage ?? model.validationMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Button("Cancel", role: .cancel, action: onCancel)
                .frame(width: 84)
                .disabled(isApplying)
            Button("Apply Split", systemImage: "arrow.trianglehead.branch") {
                apply()
            }
            .buttonStyle(.borderedProminent)
            .frame(width: 120)
            .disabled(!model.canApply || isApplying)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
    }

    private var loadFailure: some View {
        VStack(spacing: 12) {
            Label(errorMessage ?? "Could not load the split plan.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            Button("Retry", systemImage: "arrow.clockwise") {
                Task { await load() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableView(reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.trianglehead.branch")
                .font(.title)
                .foregroundStyle(theme.color("fg-dim"))
            Text("Split Commit Unavailable")
                .font(.headline)
            Text(reason)
                .foregroundStyle(theme.color("fg-dim"))
            Button("Close Tab", systemImage: "xmark", action: onCancel)
        }
        .padding(24)
    }

    private func load() async {
        guard model.isAvailable else {
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            try await model.load()
            onDraftChange(model.draft)
        } catch {
            errorMessage = GGErrorPresentation.message(for: error)
        }
        isLoading = false
    }

    private func apply() {
        guard !isApplying else { return }
        isApplying = true
        errorMessage = nil
        Task { @MainActor in
            defer { isApplying = false }
            do {
                try await model.apply()
                onCancel()
            } catch {
                errorMessage = GGErrorPresentation.message(for: error)
            }
        }
    }
}

enum GGResultingImagePreview {
    struct Partition: Equatable {
        let imagePaths: [String]
        let otherPaths: [String]
    }

    static func partition(_ paths: [String]) -> Partition {
        Partition(
            imagePaths: paths.filter(ImageFileType.isSupported(relativePath:)),
            otherPaths: paths.filter { !ImageFileType.isSupported(relativePath: $0) }
        )
    }
}

private struct GGSplitResultingImagePreview: View {
    let path: String
    let worktreePath: URL
    let revision: String
    let codeFontFamily: String
    let codeFontSize: CGFloat

    @State private var imageSide: ImageDiffSide?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(path)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                ImageCheckerboardBackground()
                if let image = imageSide?.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else if imageSide == nil {
                    Spinner()
                        .frame(width: 20, height: 20)
                } else {
                    Label("Could not load image", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
        }
        .task(id: "\(worktreePath.path):\(revision):\(path)") {
            imageSide = await GitService().imageSide(
                worktreePath: worktreePath,
                revision: revision,
                path: path
            )
        }
    }
}
