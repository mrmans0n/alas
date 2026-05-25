import SwiftUI
import AppKit

struct MergeConflictBinaryView: View {
    let conflictedFile: ConflictedFile
    let worktreePath: URL
    let loadGeneration: Int
    @Environment(\.theme) var theme

    private var isImage: Bool {
        ImageFileType.isSupported(relativePath: conflictedFile.relativePath)
    }

    var body: some View {
        if isImage {
            imageSideBySide
        } else {
            nonImageBanner
        }
    }

    @ViewBuilder
    private var imageSideBySide: some View {
        HStack(spacing: 0) {
            imageColumn(title: "LOCAL · ours", stage: 2)
            Divider()
            imageColumn(title: "REMOTE · theirs", stage: 3)
        }
    }

    private func imageColumn(title: String, stage: Int) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .foregroundColor(theme.color("fg-dim"))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("bg-2"))
            ImageStageView(
                worktreePath: worktreePath,
                relativePath: conflictedFile.relativePath,
                stage: stage,
                loadGeneration: loadGeneration
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var nonImageBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 36))
                .foregroundColor(theme.color("fg-dim"))
            Text("Binary conflict")
                .font(.system(size: 14, weight: .semibold))
            Text("This file's contents can't be merged in the text editor.\nUse the right-pane Conflicts section to pick a side via Use ours / Use theirs, then Mark resolved here.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}

/// Loads an image from a specific git index stage (`:N:<path>`) and renders
/// it via `NSImageView`. Uses `Process.gitData` (raw bytes, not UTF-8) so
/// binary payloads aren't corrupted.
private struct ImageStageView: NSViewRepresentable {
    let worktreePath: URL
    let relativePath: String
    let stage: Int
    let loadGeneration: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.imageFrameStyle = .none
        view.animates = false
        loadIfNeeded(into: view, context: context)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        loadIfNeeded(into: view, context: context)
    }

    private func loadIfNeeded(into view: NSImageView, context: Context) {
        let key = "\(worktreePath.path)\n\(relativePath)\n\(stage)\n\(loadGeneration)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key

        // Cancel any in-flight load — its result, if it arrives now, would be
        // for a stale key and would overwrite the just-requested image.
        context.coordinator.loadTask?.cancel()

        let coordinator = context.coordinator
        let capturedKey = key
        let capturedStage = stage
        let capturedPath = relativePath
        let capturedCwd = worktreePath
        coordinator.loadTask = Task {
            let data = await Self.readStageData(stage: capturedStage, path: capturedPath, cwd: capturedCwd)
            if Task.isCancelled { return }
            await MainActor.run {
                // Defensive: only apply if the coordinator's key still matches
                // what this Task was started for. If the user switched again
                // mid-await, the new task already updated lastKey and we'd be
                // setting an image for an outdated request.
                guard coordinator.lastKey == capturedKey else { return }
                if let data, let image = NSImage(data: data) {
                    view.image = image
                } else {
                    view.image = nil
                }
            }
        }
    }

    private static func readStageData(stage: Int, path: String, cwd: URL) async -> Data? {
        let result = try? await Process.gitData(
            ["show", ":\(stage):\(path)"],
            cwd: cwd
        )
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdout
    }

    final class Coordinator {
        var lastKey: String?
        var loadTask: Task<Void, Never>?

        deinit {
            loadTask?.cancel()
        }
    }
}
