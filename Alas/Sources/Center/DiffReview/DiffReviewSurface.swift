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

    @Environment(\.theme) private var theme
    @State private var programmaticScroll = DiffReviewProgrammaticScrollController()
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

        return ScrollViewReader { scrollProxy in
            HStack(spacing: 0) {
                DiffReviewRail(
                    session: session.summary,
                    selectedFileID: selectedBinding,
                    collapsed: $railCollapsed,
                    displayControls: showsRailDisplayControls ? DiffReviewDisplayControlBindings(
                        layoutMode: $layoutMode,
                        wrapLines: $wrapLines,
                        showWhitespace: $showWhitespace
                    ) : nil,
                    onSelectFile: { id in
                        scrollToFile(id, proxy: scrollProxy)
                    }
                )
                mainReviewStream(session)
            }
        }
    }

    private func mainReviewStream(_ session: DiffReviewLoadedSession) -> some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.files) { file in
                        DiffReviewFileSection(
                            file: file,
                            layoutMode: $layoutMode,
                            wrapLines: $wrapLines,
                            showWhitespace: $showWhitespace,
                            codeFontFamily: codeFontFamily,
                            codeFontSize: codeFontSize,
                            showsSourceBadge: showsSourceBadges,
                            lspContext: lspContextForFile(file)
                        )
                        .id(file.summary.id.rawValue)
                        .background(sectionFrameReader(for: file.summary.id))
                    }
                }
                .padding(16)
            }
            .coordinateSpace(name: Self.scrollCoordinateSpace)
            .onPreferenceChange(DiffReviewSectionFramePreferenceKey.self) { frames in
                updateSelectedFileFromScroll(frames: frames, viewportHeight: viewport.size.height)
            }
        }
        .background(theme.color("bg-1"))
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
    }

    private func scrollToFile(_ id: DiffReviewFileID, proxy: ScrollViewProxy) {
        selectedFileID = id
        let token = programmaticScroll.beginProgrammaticScroll(to: id)

        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(id.rawValue, anchor: .top)
        }

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

struct DiffReviewSectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [DiffReviewSectionFrame] = []

    static func reduce(value: inout [DiffReviewSectionFrame], nextValue: () -> [DiffReviewSectionFrame]) {
        value.append(contentsOf: nextValue())
    }
}
