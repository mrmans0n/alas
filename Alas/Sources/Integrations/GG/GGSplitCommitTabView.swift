import AppKit
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
    @State private var appKitPreviewScrollerEnabled = AppKitDiffScrollerFlag.isEnabled
    @State private var previewImageStore = GGSplitPreviewImageStore()
    @State private var previewPresentationStore = GGSplitPreviewPresentationStore()
    @State private var activeDestination = GGSplitCommitDestination.newCommit
    @State private var collapsedFileGroupIDs: Set<String> = []
    @State private var previewScrollCoordinator = GGSplitPreviewScrollRequestCoordinator()
    @State private var previewScrollRequest: AppKitDiffScrollRequest?
    @State private var legacyScrollPath: String?
    @State private var legacyScrollGeneration = 0

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
        .onReceive(
            NotificationCenter.default.publisher(for: AppKitDiffScrollerFlag.overrideDidChangeNotification)
        ) { _ in
            appKitPreviewScrollerEnabled = AppKitDiffScrollerFlag.isEnabled
        }
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
                HSplitView {
                    selectionPane
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 460)
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
            HStack {
                Text("Changes")
                    .font(.headline)
                Spacer()
                Text("\(model.selectedHunkIDs.count) new · \(originalHunkCount) original")
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-dim"))
            }
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if group.kind == .selectable {
                    Button {
                        if collapsedFileGroupIDs.contains(group.id) {
                            collapsedFileGroupIDs.remove(group.id)
                        } else {
                            collapsedFileGroupIDs.insert(group.id)
                        }
                    } label: {
                        Label {
                            Text(group.path)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: collapsedFileGroupIDs.contains(group.id) ? "chevron.right" : "chevron.down")
                        }
                        .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                    }
                    .buttonStyle(.plain)
                    .help(collapsedFileGroupIDs.contains(group.id) ? "Expand file" : "Collapse file")
                    Spacer(minLength: 4)
                    Menu("Assign all") {
                        Button("New Commit") { assign(group, to: .newCommit) }
                        Button("Original Commit") { assign(group, to: .originalCommit) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("gg-split-file-assign-\(group.id)")
                } else {
                    Label(group.path, systemImage: "doc")
                        .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("Original only")
                        .font(.caption)
                        .foregroundStyle(theme.color("fg-dim"))
                }
            }
            .padding(12)

            if group.kind == .selectable, !collapsedFileGroupIDs.contains(group.id) {
                ForEach(group.hunks, id: \.id) { hunk in
                    splitHunkRow(hunk)
                }
            }
        }
        .overlay(Divider(), alignment: .bottom)
    }

    private func splitHunkRow(_ hunk: GGSplitHunk) -> some View {
        let destination = model.destination(for: hunk.id) ?? .originalCommit
        return HStack(alignment: .top, spacing: 8) {
            Button {
                focusPreview(destination: destination, path: hunk.path)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hunk.header)
                        .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                        .foregroundStyle(theme.color("fg"))
                        .lineLimit(1)
                    Text(hunk.patch)
                        .font(CenterTypography.codeFont(family: codeFontFamily, size: max(9, codeFontSize - 2)))
                        .foregroundStyle(theme.color("fg-dim"))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(destination.title) preview for \(hunk.header)")

            Button(destination.shortTitle) {
                assign(hunk, to: destination.other)
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.medium))
            .foregroundStyle(destination == .newCommit ? theme.color("add") : theme.color("fg"))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(destination == .newCommit ? theme.color("add").opacity(0.14) : theme.color("bg-3"))
            .clipShape(.capsule)
            .help("Move to \(destination.other.title)")
            .accessibilityLabel("Assigned to \(destination.title)")
            .accessibilityHint("Moves this hunk to \(destination.other.title)")
            .accessibilityIdentifier("gg-split-hunk-destination-\(hunk.id)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.color("bg-1").opacity(0.35))
        .overlay(Divider(), alignment: .bottom)
    }

    private var editorAndPreviews: some View {
        VStack(spacing: 0) {
            commitCards
            Divider()
            previewPane(
                destination: activeDestination,
                preview: activePreview,
                showsResultingImages: activeDestination == .originalCommit
            )
            Divider()
            actionBar
        }
    }

    private var commitCards: some View {
        HStack(spacing: 10) {
            commitCard(
                destination: .newCommit,
                message: $model.firstMessage,
                preview: model.firstPreview
            )
            commitCard(
                destination: .originalCommit,
                message: $model.remainderMessage,
                preview: model.remainderPreview
            )
        }
        .padding(12)
        .background(theme.color("bg-2"))
    }

    private func commitCard(
        destination: GGSplitCommitDestination,
        message: Binding<String>,
        preview: GGSplitPreview
    ) -> some View {
        let isActive = activeDestination == destination
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                activeDestination = destination
                previewScrollRequest = nil
            } label: {
                HStack {
                    Text(destination.title)
                        .font(.headline)
                    Spacer()
                    Text(contentSummary(for: preview))
                        .font(.caption)
                        .foregroundStyle(theme.color("fg-dim"))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show \(destination.title) preview")
            .accessibilityValue(isActive ? "Selected" : "Not selected")
            .accessibilityIdentifier("gg-split-commit-card-\(destination.previewID)")

            PairedTextField(
                text: message,
                placeholder: "Commit message",
                font: .systemFont(ofSize: NSFont.systemFontSize),
                textColor: NSColor(theme.color("fg")),
                isEnabled: !isApplying
            )
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(theme.color("field-bg"))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(theme.color("border"), lineWidth: 1)
                )
                .onChange(of: message.wrappedValue) { draftDidChange() }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(isActive ? theme.color("accent").opacity(0.09) : theme.color("bg-1"))
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? theme.color("accent") : theme.color("border"), lineWidth: isActive ? 2 : 1)
        }
    }

    private func previewPane(
        destination: GGSplitCommitDestination,
        preview: GGSplitPreview,
        showsResultingImages: Bool = false
    ) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(destination.title)
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
                previewScrollSubtree(
                    previewID: destination.previewID,
                    preview: preview,
                    showsResultingImages: showsResultingImages
                )
                .id(appKitPreviewScrollerEnabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    nonisolated static func usesAppKitPreviewScroller(flagEnabled: Bool) -> Bool {
        flagEnabled
    }

    @ViewBuilder
    private func previewScrollSubtree(
        previewID: String,
        preview: GGSplitPreview,
        showsResultingImages: Bool
    ) -> some View {
        if Self.usesAppKitPreviewScroller(flagEnabled: appKitPreviewScrollerEnabled) {
            AppKitDiffScroller(
                plan: GGSplitPreviewRowPlanBuilder.build(input: .init(
                    previewID: previewID,
                    preview: preview,
                    showsResultingImages: showsResultingImages,
                    worktreePath: worktreePath,
                    revision: model.targetSHA,
                    layoutMode: layoutMode,
                    wrapLines: wrapLines,
                    showWhitespace: showWhitespace,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    theme: theme,
                    imageStore: previewImageStore,
                    presentationStore: previewPresentationStore
                )),
                scrollRequest: previewScrollRequest,
                onActiveOwnerChange: { _ in },
                onScrollRequestCompletion: { generation in
                    if previewScrollRequest?.generation == generation {
                        previewScrollRequest = nil
                    }
                }
            )
        } else {
            legacyPreviewScroll(preview: preview, showsResultingImages: showsResultingImages)
        }
    }

    private func legacyPreviewScroll(
        preview: GGSplitPreview,
        showsResultingImages: Bool
    ) -> some View {
        let partition = GGResultingImagePreview.partition(preview.nonTextualFiles)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(preview.files) { file in
                        splitPreviewFile(file)
                            .id(GGSplitPreviewRowID.legacyFile(path: file.path))
                    }
                    if showsResultingImages, let targetSHA = model.targetSHA {
                        ForEach(partition.imagePaths, id: \.self) { path in
                            let key = GGSplitPreviewImageKey(
                                worktreePath: worktreePath, revision: targetSHA, relativePath: path
                            )
                            GGSplitResultingImagePreview(
                                key: key,
                                state: previewImageStore.state(for: key),
                                codeFontFamily: codeFontFamily,
                                codeFontSize: codeFontSize
                            )
                            .id(GGSplitPreviewRowID.legacyImage(path: path))
                        }
                    }
                    ForEach(partition.otherPaths, id: \.self) { path in
                        Label(path, systemImage: "doc")
                            .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                            .foregroundStyle(theme.color("fg-dim"))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(GGSplitPreviewRowID.legacyOther(path: path))
                    }
                }
            }
            .onChange(of: legacyScrollGeneration) {
                guard let legacyScrollPath else { return }
                withAnimation { proxy.scrollTo(legacyScrollPath, anchor: .top) }
            }
        }
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

    private var originalHunkCount: Int {
        max(0, (model.description?.hunks.count ?? 0) - model.selectedHunkIDs.count)
    }

    private var activePreview: GGSplitPreview {
        switch activeDestination {
        case .newCommit: model.firstPreview
        case .originalCommit: model.remainderPreview
        }
    }

    private func contentSummary(for preview: GGSplitPreview) -> String {
        let hunkCount = preview.files.flatMap(\.hunkIDs).count
        let fileCount = Set(preview.files.map(\.path) + preview.nonTextualFiles).count
        return "\(hunkCount) hunk\(hunkCount == 1 ? "" : "s") · \(fileCount) file\(fileCount == 1 ? "" : "s")"
    }

    private func assign(_ hunk: GGSplitHunk, to destination: GGSplitCommitDestination) {
        model.assignHunk(hunk.id, to: destination)
        draftDidChange()
    }

    private func assign(_ group: GGSplitCommitFileGroup, to destination: GGSplitCommitDestination) {
        model.assignHunks(in: group, to: destination)
        draftDidChange()
    }

    private func draftDidChange() {
        errorMessage = nil
        onDraftChange(model.draft)
    }

    private func focusPreview(destination: GGSplitCommitDestination, path: String) {
        activeDestination = destination
        previewScrollRequest = previewScrollCoordinator.request(
            previewID: destination.previewID,
            path: path
        )
        legacyScrollPath = GGSplitPreviewRowID.legacyFile(path: path)
        legacyScrollGeneration += 1
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

private extension GGSplitCommitDestination {
    var title: String {
        switch self {
        case .newCommit: "New Commit"
        case .originalCommit: "Original Commit"
        }
    }

    var shortTitle: String {
        switch self {
        case .newCommit: "New"
        case .originalCommit: "Original"
        }
    }

    var previewID: String {
        switch self {
        case .newCommit: "new"
        case .originalCommit: "original"
        }
    }

    var other: Self {
        switch self {
        case .newCommit: .originalCommit
        case .originalCommit: .newCommit
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
