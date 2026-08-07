import Observation
import SwiftUI

struct GGSplitPreviewImageKey: Hashable {
    let worktreePath: URL
    let revision: String
    let relativePath: String

    init(worktreePath: URL, revision: String, relativePath: String) {
        self.worktreePath = worktreePath.standardizedFileURL
        self.revision = revision
        self.relativePath = relativePath
    }
}

@Observable
@MainActor
final class GGSplitPreviewImageState {
    private(set) var imageSide: ImageDiffSide?
    private(set) var isLoading = true
    @ObservationIgnored private var loadedKey: GGSplitPreviewImageKey?

    func load(key: GGSplitPreviewImageKey) async {
        guard loadedKey != key || imageSide == nil else { return }
        loadedKey = key
        isLoading = true
        imageSide = await GitService().imageSide(
            worktreePath: key.worktreePath,
            revision: key.revision,
            path: key.relativePath
        )
        isLoading = false
    }
}

@MainActor
final class GGSplitPreviewImageStore {
    private var states: [GGSplitPreviewImageKey: GGSplitPreviewImageState] = [:]

    func state(for key: GGSplitPreviewImageKey) -> GGSplitPreviewImageState {
        if let state = states[key] { return state }
        let state = GGSplitPreviewImageState()
        states[key] = state
        return state
    }

    func prune(keeping keys: Set<GGSplitPreviewImageKey>) {
        states = states.filter { keys.contains($0.key) }
    }

    #if DEBUG
    var keysForTests: Set<GGSplitPreviewImageKey> { Set(states.keys) }
    #endif
}

@MainActor
final class GGSplitPreviewPresentationStore {
    private var states: [String: DiffPanePresentationState] = [:]

    func state(previewID: String, filePath: String) -> DiffPanePresentationState {
        let key = "\(previewID):\(filePath)"
        if let state = states[key] { return state }
        let state = DiffPanePresentationState()
        states[key] = state
        return state
    }

    func prune(previewID: String, keeping keys: Set<String>) {
        let prefix = "\(previewID):"
        states = states.filter { key, _ in
            !key.hasPrefix(prefix) || keys.contains(key)
        }
    }

    #if DEBUG
    var keysForTests: Set<String> { Set(states.keys) }
    #endif
}

@MainActor
struct GGSplitPreviewRowPlanInput {
    let previewID: String
    let preview: GGSplitPreview
    let showsResultingImages: Bool
    let worktreePath: URL
    let revision: String?
    let layoutMode: DiffLayoutMode
    let wrapLines: Bool
    let showWhitespace: Bool
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme
    let imageStore: GGSplitPreviewImageStore
    let presentationStore: GGSplitPreviewPresentationStore
}

private struct GGSplitPreviewHeaderToken: Equatable {
    let previewID: String
    let path: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme
}

private struct GGSplitPreviewImageToken: Equatable {
    let previewID: String
    let key: GGSplitPreviewImageKey
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme
}

private struct GGSplitPreviewHunkWrapperToken: Equatable {
    let content: AppKitDiffRowEqualityToken
    let topPadding: CGFloat
    let bottomPadding: CGFloat
}

@MainActor
enum GGSplitPreviewRowPlanBuilder {
    static func build(input: GGSplitPreviewRowPlanInput) -> AppKitDiffRowPlan {
        var rows: [AppKitDiffRowSpec] = []
        let presentationKeys = Set(input.preview.files.map { "\(input.previewID):\($0.path)" })
        input.presentationStore.prune(previewID: input.previewID, keeping: presentationKeys)
        for file in input.preview.files {
            let prefix = "gg-preview:\(input.previewID):file:\(file.path)"
            rows.append(.init(
                id: "\(prefix):header",
                ownerID: file.path,
                equalityToken: .init(GGSplitPreviewHeaderToken(
                    previewID: input.previewID,
                    path: file.path,
                    codeFontFamily: input.codeFontFamily,
                    codeFontSize: input.codeFontSize,
                    theme: input.theme
                )),
                estimatedHeight: 35
            ) {
                AnyView(GGSplitPreviewFileHeaderRow(
                    path: file.path,
                    codeFontFamily: input.codeFontFamily,
                    codeFontSize: input.codeFontSize,
                    theme: input.theme
                ))
            })

            let model = DiffDisplayModelBuilder.build(diff: file.diff, filePath: file.path)
            let fusionStates = DiffPaneHunkFusionResolver.states(for: model.groups)
            let hunkPlan = DiffPaneRowPlanBuilder.build(
                input: .init(
                    model: model,
                    fileExtension: LanguageRegistry.highlighterExtension(forPath: file.path),
                    layoutMode: input.layoutMode,
                    wrapLines: input.wrapLines,
                    showWhitespace: input.showWhitespace,
                    codeFontFamily: input.codeFontFamily,
                    codeFontSize: input.codeFontSize,
                    theme: input.theme,
                    allowsReviewLineSelection: false,
                    hunkActions: { _ in DiffPaneHunkActions() }
                ),
                state: input.presentationStore.state(previewID: input.previewID, filePath: file.path)
            )
            for (index, hunk) in hunkPlan.rows.enumerated() {
                let topPadding = index == hunkPlan.rows.startIndex ? fusionStates.first?.outerTopPadding ?? 10 : 0
                let bottomPadding = index == hunkPlan.rows.index(before: hunkPlan.rows.endIndex)
                    ? fusionStates.last?.outerBottomPadding ?? 10
                    : 0
                rows.append(.init(
                    id: "\(prefix):hunk:\(index):\(hunk.id)",
                    ownerID: file.path,
                    equalityToken: .init(GGSplitPreviewHunkWrapperToken(
                        content: hunk.equalityToken,
                        topPadding: topPadding,
                        bottomPadding: bottomPadding
                    )),
                    estimatedHeight: hunk.estimatedHeight + topPadding + bottomPadding,
                    retention: hunk.retention
                ) {
                    AnyView(
                        hunk.build()
                            .padding(.horizontal, 10)
                            .padding(.top, topPadding)
                            .padding(.bottom, bottomPadding)
                    )
                })
            }
        }

        let partition = GGResultingImagePreview.partition(input.preview.nonTextualFiles)
        let imageKeys: Set<GGSplitPreviewImageKey>
        if input.showsResultingImages, let revision = input.revision {
            imageKeys = Set(partition.imagePaths.map {
                GGSplitPreviewImageKey(
                    worktreePath: input.worktreePath,
                    revision: revision,
                    relativePath: $0
                )
            })
            input.imageStore.prune(keeping: imageKeys)
            for path in partition.imagePaths {
                let key = GGSplitPreviewImageKey(
                    worktreePath: input.worktreePath,
                    revision: revision,
                    relativePath: path
                )
                let state = input.imageStore.state(for: key)
                rows.append(.init(
                    id: "gg-preview:\(input.previewID):image:\(key.relativePath)",
                    ownerID: key.relativePath,
                    equalityToken: .init(GGSplitPreviewImageToken(
                        previewID: input.previewID,
                        key: key,
                        codeFontFamily: input.codeFontFamily,
                        codeFontSize: input.codeFontSize,
                        theme: input.theme
                    )),
                    estimatedHeight: 255
                ) {
                    AnyView(GGSplitResultingImagePreview(
                        key: key,
                        state: state,
                        codeFontFamily: input.codeFontFamily,
                        codeFontSize: input.codeFontSize
                    ))
                })
            }
        } else {
            imageKeys = []
        }

        for path in partition.otherPaths {
            rows.append(.init(
                id: "gg-preview:\(input.previewID):other:\(path)",
                ownerID: path,
                equalityToken: .init(GGSplitPreviewHeaderToken(
                    previewID: input.previewID,
                    path: path,
                    codeFontFamily: input.codeFontFamily,
                    codeFontSize: input.codeFontSize,
                    theme: input.theme
                )),
                estimatedHeight: 43
            ) {
                AnyView(GGSplitPreviewOtherFileRow(
                    path: path,
                    codeFontFamily: input.codeFontFamily,
                    codeFontSize: input.codeFontSize,
                    theme: input.theme
                ))
            })
        }
        return .init(rows: rows)
    }
}

private struct GGSplitPreviewFileHeaderRow: View {
    let path: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme

    var body: some View {
        Text(path)
            .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
            .foregroundStyle(theme.color("fg"))
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }
}

private struct GGSplitPreviewOtherFileRow: View {
    let path: String
    let codeFontFamily: String
    let codeFontSize: CGFloat
    let theme: Theme

    var body: some View {
        Label(path, systemImage: "doc")
            .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
            .foregroundStyle(theme.color("fg-dim"))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GGSplitResultingImagePreview: View {
    let key: GGSplitPreviewImageKey
    let state: GGSplitPreviewImageState
    let codeFontFamily: String
    let codeFontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(key.relativePath)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: max(10, codeFontSize - 1)))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                ImageCheckerboardBackground()
                if let image = state.imageSide?.image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else if state.isLoading {
                    Spinner().frame(width: 20, height: 20)
                } else {
                    Label("Could not load image", systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
        }
        .task(id: key) { await state.load(key: key) }
    }
}
