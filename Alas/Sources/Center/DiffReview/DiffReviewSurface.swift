import SwiftUI

struct DiffReviewSurface: View {
    let session: DiffReviewLoadedSession
    @Binding var selectedFileID: DiffReviewFileID?
    @Binding var railCollapsed: Bool
    @Binding var layoutMode: DiffLayoutMode
    @Binding var wrapLines: Bool
    @Binding var showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    var showsSourceBadges: Bool = true
    var showsRailDisplayControls: Bool = false
    var lspContextForFile: (DiffReviewFileSectionModel) -> DiffPaneLSPContext? = { _ in nil }
    var inlineFeedbackByFileID: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [:]
    var focusedFeedbackID: String? = nil
    var inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand? = nil
    var inlineFeedbackActions = DiffReviewInlineFeedbackActions()
    var onSelectInlineFeedback: (DiffReviewInlineFeedback) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @State private var programmaticScroll = DiffReviewProgrammaticScrollController()
    @State private var scrollCommandController = DiffReviewScrollCommandController()
    @State private var scrollCommand: DiffReviewScrollCommand?
    @State private var renderedFileIDs: Set<DiffReviewFileID> = []
    @State private var synchronizedFileSetKey: String?

    private static let scrollCoordinateSpace = "diff-review-scroll"

    private var fileIDs: [DiffReviewFileID] {
        session.summary.files.map(\.id)
    }

    private var fileSetKey: String {
        DiffReviewSurfaceSelectionSync.fileSetKey(for: fileIDs)
    }

    var body: some View {
        Group {
            if let firstFileID = session.summary.files.first?.id {
                reviewSurface(firstFileID: firstFileID)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(theme.color("bg-1"))
            }
        }
        .onAppear {
            synchronizeSelectionWithSession()
        }
        .onChange(of: fileSetKey) { _, _ in
            synchronizeSelectionWithSession()
        }
    }

    private func reviewSurface(firstFileID: DiffReviewFileID) -> some View {
        let selectedBinding = Binding<DiffReviewFileID>(
            get: { selectedFileID ?? firstFileID },
            set: { selectedFileID = $0 }
        )

        return HStack(spacing: 0) {
            DiffReviewRail(
                session: session.summary,
                selectedFileID: selectedBinding,
                collapsed: $railCollapsed,
                displayControls: showsRailDisplayControls ? DiffReviewDisplayControlBindings(
                    layoutMode: $layoutMode,
                    wrapLines: $wrapLines,
                    showWhitespace: $showWhitespace
                ) : nil,
                onSelectFile: scrollToFile
            )
            mainReviewStream(session, firstFileID: firstFileID)
        }
    }

    private func mainReviewStream(_ session: DiffReviewLoadedSession, firstFileID: DiffReviewFileID) -> some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        let renderedIDs = effectiveRenderedFileIDs(firstFileID: firstFileID)
                        ForEach(session.files) { file in
                            fileSection(file, isRendered: renderedIDs.contains(file.id))
                                .id(file.summary.id.rawValue)
                                .background(sectionFrameReader(for: file.summary.id))
                        }
                    }
                    .padding(16)
                }
                .coordinateSpace(name: Self.scrollCoordinateSpace)
                .onPreferenceChange(DiffReviewSectionFramePreferenceKey.self) { frames in
                    updateSelectedFileFromScroll(frames: frames, viewportHeight: viewport.size.height)
                    updateRenderedFileIDs(
                        frames: frames,
                        viewportHeight: viewport.size.height,
                        firstFileID: firstFileID
                    )
                }
                .onChange(of: scrollCommand) { _, command in
                    guard let command else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        scrollProxy.scrollTo(command.id.rawValue, anchor: .top)
                    }
                }
                .onAppear {
                    guard let command = inlineFeedbackScrollCommand else { return }
                    Task { @MainActor in
                        scrollToInlineFeedback(command, scrollProxy: scrollProxy, animated: false)
                    }
                }
                .onChange(of: inlineFeedbackScrollCommand) { _, command in
                    guard let command else { return }
                    scrollToInlineFeedback(command, scrollProxy: scrollProxy, animated: true)
                }
            }
        }
        .background(theme.color("bg-1"))
    }

    @ViewBuilder
    private func fileSection(_ file: DiffReviewFileSectionModel, isRendered: Bool) -> some View {
        let inlineFeedback = inlineFeedbackByFileID[file.id] ?? []
        if isRendered {
            DiffReviewFileSection(
                file: file,
                inlineFeedback: inlineFeedback,
                focusedFeedbackID: focusedFeedbackID,
                layoutMode: $layoutMode,
                wrapLines: $wrapLines,
                showWhitespace: $showWhitespace,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize,
                showsSourceBadge: showsSourceBadges,
                lspContext: lspContextForFile(file),
                inlineFeedbackActions: inlineFeedbackActions,
                onSelectInlineFeedback: onSelectInlineFeedback
            )
        } else {
            DiffReviewFileSectionPlaceholder(
                file: file,
                estimatedHeight: DiffReviewFileSectionHeightEstimator.estimatedHeight(
                    for: file,
                    inlineFeedback: inlineFeedback
                ),
                showsSourceBadge: showsSourceBadges,
                codeFontFamily: codeFontFamily,
                codeFontSize: codeFontSize
            )
        }
    }

    private func scrollToInlineFeedback(
        _ command: DiffReviewInlineFeedbackScrollCommand,
        scrollProxy: ScrollViewProxy,
        animated: Bool
    ) {
        selectedFileID = command.fileID
        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                scrollProxy.scrollTo(command.targetID, anchor: .center)
            }
        } else {
            scrollProxy.scrollTo(command.targetID, anchor: .center)
        }
    }

    private func effectiveRenderedFileIDs(firstFileID: DiffReviewFileID) -> Set<DiffReviewFileID> {
        DiffReviewRenderWindow.renderedFileIDs(
            current: renderedFileIDs,
            frames: [],
            viewportHeight: 0,
            selectedFileID: selectedFileID,
            programmaticTarget: DiffReviewSurfaceSelectionSync.renderedTargetFileID(
                fileScrollTarget: programmaticScroll.target,
                inlineFeedbackScrollCommand: inlineFeedbackScrollCommand
            ),
            firstFileID: firstFileID
        )
    }

    private func sectionFrameReader(for id: DiffReviewFileID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: DiffReviewSectionFramePreferenceKey.self,
                value: [
                    DiffReviewSectionFrame(
                        id: id,
                        minY: proxy.frame(in: .named(Self.scrollCoordinateSpace)).minY,
                        maxY: proxy.frame(in: .named(Self.scrollCoordinateSpace)).maxY
                    ),
                ]
            )
        }
    }

    private func updateSelectedFileFromScroll(frames: [DiffReviewSectionFrame], viewportHeight: CGFloat) {
        guard let updated = DiffReviewActiveFileSelection.updatedSelection(
            current: selectedFileID,
            frames: frames,
            viewportHeight: viewportHeight,
            programmaticScroll: programmaticScroll
        ) else { return }

        selectedFileID = updated
    }

    private func updateRenderedFileIDs(
        frames: [DiffReviewSectionFrame],
        viewportHeight: CGFloat,
        firstFileID: DiffReviewFileID
    ) {
        let updated = DiffReviewRenderWindow.renderedFileIDs(
            current: renderedFileIDs,
            frames: frames,
            viewportHeight: viewportHeight,
            selectedFileID: selectedFileID,
            programmaticTarget: DiffReviewSurfaceSelectionSync.renderedTargetFileID(
                fileScrollTarget: programmaticScroll.target,
                inlineFeedbackScrollCommand: inlineFeedbackScrollCommand
            ),
            firstFileID: firstFileID
        )
        guard updated != renderedFileIDs else { return }

        renderedFileIDs = updated
    }

    private func synchronizeSelectionWithSession() {
        let result = DiffReviewSurfaceSelectionSync.synchronize(
            current: selectedFileID,
            previousFileSetKey: synchronizedFileSetKey,
            fileIDs: fileIDs,
            programmaticScroll: programmaticScroll
        )

        selectedFileID = result.selectedFileID
        synchronizedFileSetKey = result.fileSetKey
        programmaticScroll = result.programmaticScroll
        renderedFileIDs = []
    }

    private func scrollToFile(_ id: DiffReviewFileID) {
        selectedFileID = id
        let token = programmaticScroll.beginProgrammaticScroll(to: id)
        scrollCommand = scrollCommandController.command(to: id)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            programmaticScroll.finishProgrammaticScroll(token)
        }
    }
}

enum DiffReviewSurfaceSelectionSync {
    struct Result {
        let selectedFileID: DiffReviewFileID?
        let fileSetKey: String
        let programmaticScroll: DiffReviewProgrammaticScrollController
    }

    static func fileSetKey(for fileIDs: [DiffReviewFileID]) -> String {
        fileIDs.map { "\($0.rawValue.count):\($0.rawValue)" }.joined(separator: "|")
    }

    static func synchronizedSelection(
        current: DiffReviewFileID?,
        fileIDs: [DiffReviewFileID]
    ) -> DiffReviewFileID? {
        guard let first = fileIDs.first else { return nil }

        if let current, fileIDs.contains(current) {
            return current
        }

        return first
    }

    static func renderedTargetFileID(
        fileScrollTarget: DiffReviewFileID?,
        inlineFeedbackScrollCommand: DiffReviewInlineFeedbackScrollCommand?
    ) -> DiffReviewFileID? {
        inlineFeedbackScrollCommand?.fileID ?? fileScrollTarget
    }

    static func synchronize(
        current: DiffReviewFileID?,
        previousFileSetKey: String?,
        fileIDs: [DiffReviewFileID],
        programmaticScroll: DiffReviewProgrammaticScrollController
    ) -> Result {
        let nextFileSetKey = fileSetKey(for: fileIDs)
        let didChangeFileSet = previousFileSetKey != nil && previousFileSetKey != nextFileSetKey

        return Result(
            selectedFileID: synchronizedSelection(current: current, fileIDs: fileIDs),
            fileSetKey: nextFileSetKey,
            programmaticScroll: didChangeFileSet ? DiffReviewProgrammaticScrollController() : programmaticScroll
        )
    }
}

extension DiffReviewFileSectionHeightEstimator {
    static func estimatedHeight(for file: DiffReviewFileSectionModel, inlineFeedbackCount: Int) -> CGFloat {
        estimatedHeight(for: file)
            + DiffReviewInlineFeedbackDisplayPolicy.estimatedHeight(for: inlineFeedbackCount)
    }

    static func estimatedHeight(
        for file: DiffReviewFileSectionModel,
        inlineFeedback: [DiffReviewInlineFeedback]
    ) -> CGFloat {
        guard let displayModel = file.displayModel else {
            return estimatedHeight(for: file)
                + DiffReviewInlineFeedbackDisplayPolicy.estimatedHeight(for: inlineFeedback)
        }

        let placement = DiffReviewInlineFeedbackPlacement.position(inlineFeedback, in: displayModel.groups)
        let fileLevelHeight = DiffReviewInlineFeedbackDisplayPolicy.estimatedHeight(for: placement.fileLevel)
        let groupHeights = placement.byGroupID.values.reduce(CGFloat(0)) { total, groupFeedback in
            total + DiffReviewInlineFeedbackDisplayPolicy.estimatedHeight(for: groupFeedback)
        }

        return estimatedHeight(for: file) + fileLevelHeight + groupHeights
    }
}

struct DiffReviewSectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [DiffReviewSectionFrame] = []

    static func reduce(value: inout [DiffReviewSectionFrame], nextValue: () -> [DiffReviewSectionFrame]) {
        value.append(contentsOf: nextValue())
    }
}

private struct DiffReviewFileSectionPlaceholder: View {
    let file: DiffReviewFileSectionModel
    let estimatedHeight: CGFloat
    let showsSourceBadge: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: estimatedHeight, maxHeight: estimatedHeight)
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
        .accessibilityIdentifier("diff-review-file-section-placeholder-\(file.id.rawValue)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(file.summary.status.glyph)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(statusColor(file.summary.status))
                .frame(width: 16)
            Text(file.summary.path)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)
            sourceBadge
            Spacer(minLength: 12)
            if file.summary.additions > 0 {
                Text("+\(file.summary.additions)")
                    .foregroundColor(theme.color("add"))
            }
            if file.summary.deletions > 0 {
                Text("-\(file.summary.deletions)")
                    .foregroundColor(theme.color("del"))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var sourceBadge: some View {
        if showsSourceBadge, let title = file.summary.groupTitle {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(sourceColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sourceColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private var sourceColor: Color {
        switch file.summary.groupID ?? file.summary.namespace {
        case "unstaged":
            theme.color("warn")
        case "staged":
            theme.color("info")
        default:
            theme.color("accent")
        }
    }

    private func statusColor(_ status: DiffReviewFileStatus) -> Color {
        switch status {
        case .added:
            theme.color("add")
        case .deleted:
            theme.color("del")
        case .renamed, .copied:
            theme.color("accent")
        case .conflicted:
            theme.color("warn")
        case .modified, .unknown:
            theme.color("fg-dim")
        }
    }
}
