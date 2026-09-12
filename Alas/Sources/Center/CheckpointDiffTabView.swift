import SwiftUI

enum CheckpointDiffTabPresentation: Equatable {
    case text
    case image
    case binary(message: String)
    case unavailable(String)

    static func route(_ content: CheckpointDiffContent) -> CheckpointDiffTabPresentation {
        switch content {
        case .text:
            return .text
        case .image:
            return .image
        case .binary(let beforeByteCount, let afterByteCount):
            return .binary(message: binaryMessage(beforeByteCount: beforeByteCount, afterByteCount: afterByteCount))
        case .unavailable(let message):
            return .unavailable(message)
        }
    }

    static func binaryMessage(beforeByteCount: Int64?, afterByteCount: Int64?) -> String {
        "Binary file changed. Checkpoint: \(byteText(beforeByteCount)) · Current: \(byteText(afterByteCount))"
    }

    static func emptyTextDiffMessage(_ diff: ParsedDiff, path: String) -> String {
        diff.metadataSummary ?? "No changes for \(path)"
    }

    static func combinedContent(_ contents: [(path: String, content: CheckpointDiffContent)]) -> CheckpointDiffContent {
        guard contents.count > 1 else { return contents.first?.content ?? .unavailable("The checkpoint diff could not be loaded.") }

        if let imagePair = combinedImagePair(contents) {
            return .image(imagePair)
        }

        var hunks: [ParsedDiff.Hunk] = []
        var summaries: [String] = []
        for item in contents {
            switch item.content {
            case .text(let diff):
                if diff.hunks.isEmpty {
                    summaries.append("\(item.path): \(diff.metadataSummary ?? "No text changes.")")
                } else {
                    hunks.append(contentsOf: diff.hunks.map { hunk in
                        ParsedDiff.Hunk(
                            header: "\(item.path) \(hunk.header)",
                            oldStart: hunk.oldStart,
                            newStart: hunk.newStart,
                            lines: hunk.lines
                        )
                    })
                }
            case .image:
                summaries.append("\(item.path): Image file changed.")
            case .binary(let beforeByteCount, let afterByteCount):
                summaries.append("\(item.path): \(binaryMessage(beforeByteCount: beforeByteCount, afterByteCount: afterByteCount))")
            case .unavailable(let message):
                summaries.append("\(item.path): \(message)")
            }
        }

        return .text(.init(
            hunks: hunks,
            metadataSummary: summaries.isEmpty ? nil : summaries.joined(separator: "\n")
        ))
    }

    private static func combinedImagePair(_ contents: [(path: String, content: CheckpointDiffContent)]) -> ImageDiffPair? {
        let imageItems = contents.compactMap { item -> (path: String, pair: ImageDiffPair)? in
            guard case .image(let pair) = item.content else { return nil }
            return (item.path, pair)
        }
        guard imageItems.count == contents.count else { return nil }
        guard let before = imageItems.first(where: { !isMissing($0.pair.before) }),
              let after = imageItems.reversed().first(where: { !isMissing($0.pair.after) })
        else {
            return imageItems.first?.pair
        }
        let oldPath = before.path == after.path ? before.pair.oldPath : before.path
        return ImageDiffPair(
            before: before.pair.before,
            after: after.pair.after,
            oldPath: oldPath,
            kind: before.path == after.path ? .modified : .renamed
        )
    }

    private static func isMissing(_ side: ImageDiffSide) -> Bool {
        if case .missing = side { return true }
        return false
    }

    private static func byteText(_ count: Int64?) -> String {
        guard let count else { return "missing" }
        return "\(count) bytes"
    }
}

enum CheckpointDiffLoadKey {
    static func fingerprint(
        state: CheckpointDiffTabState,
        lineageID: String?,
        retryGeneration: Int,
        currentGeneration: Int
    ) -> String {
        "\(state.id)\u{0}\(state.memberPaths.joined(separator: "\u{0}"))\u{0}\(lineageID ?? "no-target")\u{0}\(retryGeneration)\u{0}\(currentGeneration)"
    }
}

struct CheckpointDiffTabView: View {
    let state: CheckpointDiffTabState
    let target: CheckpointWorktreeTarget?
    var service: any WorktreeCheckpointServicing = WorktreeCheckpointService()
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    var currentGeneration: Int = 0
    var onStartupRecoveryReady: () -> Void = {}

    @Environment(\.theme) private var theme
    @State private var loaded = false
    @State private var content: CheckpointDiffContent?
    @State private var displayModel: DiffDisplayModel?
    @State private var layoutMode: DiffLayoutMode = .split
    @State private var wrapLines = false
    @State private var showWhitespace = false
    @State private var retryGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            if !loaded {
                Spinner()
                    .frame(width: 20, height: 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let content {
                loadedBody(content)
            } else {
                unavailableBody("The checkpoint diff could not be loaded.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: loadKey) {
            await load()
            guard !Task.isCancelled else { return }
            onStartupRecoveryReady()
        }
    }

    private var loadKey: String {
        CheckpointDiffLoadKey.fingerprint(
            state: state,
            lineageID: target?.lineageID,
            retryGeneration: retryGeneration,
            currentGeneration: currentGeneration
        )
    }

    @ViewBuilder
    private func loadedBody(_ content: CheckpointDiffContent) -> some View {
        switch content {
        case .text(let diff):
            textBody(diff)
        case .image(let pair):
            ImageDiffView(
                pair: pair,
                relativePath: state.primaryPath,
                onOpenFile: nil,
                sourceBadge: state.checkpointLabel,
                onRetry: { retryGeneration &+= 1 }
            )
        case .binary(let beforeByteCount, let afterByteCount):
            informationalBody(CheckpointDiffTabPresentation.binaryMessage(
                beforeByteCount: beforeByteCount,
                afterByteCount: afterByteCount
            ))
        case .unavailable(let message):
            unavailableBody(message)
        }
    }

    private func textBody(_ diff: ParsedDiff) -> some View {
        VStack(spacing: 0) {
            header
            if diff.hunks.isEmpty {
                Text(CheckpointDiffTabPresentation.emptyTextDiffMessage(diff, path: state.primaryPath))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding()
            } else if let displayModel {
                DiffPaneView(
                    model: displayModel,
                    fileExtension: LanguageRegistry.highlighterExtension(forPath: state.primaryPath),
                    layoutMode: $layoutMode,
                    wrapLines: $wrapLines,
                    showWhitespace: $showWhitespace,
                    codeFontFamily: codeFontFamily,
                    codeFontSize: codeFontSize,
                    allowsReviewLineSelection: false,
                    hunkActions: { _ in DiffPaneHunkActions() }
                )
            } else {
                Spinner()
                    .frame(width: 16, height: 16)
                    .padding()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(state.memberPaths.count > 1 ? "\(state.memberPaths.count) files" : (state.primaryPath as NSString).lastPathComponent)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))
            Text(state.checkpointLabel)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("accent").opacity(0.16))
                .foregroundColor(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text(state.memberPaths.count > 1 ? state.primaryPath : (state.primaryPath as NSString).deletingLastPathComponent)
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

    private func informationalBody(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.fill")
                .font(.system(size: 28))
                .foregroundColor(theme.color("fg-muted"))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
            Text("Open the file outside the diff viewer if you need to inspect binary content.")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-muted"))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailableBody(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(theme.color("fg-muted"))
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
                .multilineTextAlignment(.center)
            Button("Retry") { retryGeneration &+= 1 }
                .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loaded = false
        content = nil
        displayModel = nil
        guard let target else {
            content = .unavailable("Checkpoint diffs are only available for local worktrees with a durable identity.")
            loaded = true
            return
        }

        let paths = state.memberPaths.isEmpty ? [state.primaryPath] : state.memberPaths
        let loadedContents = await withTaskGroup(of: (String, CheckpointDiffContent).self) { group in
            for path in paths {
                group.addTask {
                    let content = await service.diffContent(
                        target: target,
                        id: state.checkpointID,
                        path: path
                    )
                    return (path, content)
                }
            }

            var byPath: [String: CheckpointDiffContent] = [:]
            for await item in group {
                byPath[item.0] = item.1
            }
            return paths.compactMap { path in
                byPath[path].map { (path, $0) }
            }
        }
        let loadedContent = CheckpointDiffTabPresentation.combinedContent(loadedContents)
        guard !Task.isCancelled else { return }
        content = loadedContent
        if case .text(let diff) = loadedContent {
            let model = await Task.detached(priority: .userInitiated) {
                DiffDisplayModelBuilder.build(diff: diff, filePath: state.primaryPath)
            }.value
            guard !Task.isCancelled else { return }
            displayModel = diff.hunks.isEmpty ? nil : model
        }
        loaded = true
    }
}
