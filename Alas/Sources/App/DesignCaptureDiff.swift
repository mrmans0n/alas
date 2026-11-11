import Foundation

/// Design-capture targets for the diff tabs: the plain single-file diff and the
/// image diff in each of its modes, over the demo worktree's edits. Each opens
/// the tab through `AppState.openDiffTab`, the entry point the Changes tab uses
/// for a clicked file. Debug builds only; release builds get the default mode.
@MainActor
enum DesignCaptureDiff {
    /// diff-file: the text diff of Invoice.swift; image-diff-<mode>: docs/usage-chart.png in that
    /// mode; image-diff-added: docs/new-chart.png, which has no committed side.
    static let targets: Set<String> = [
        "diff-file", "image-diff-side", "image-diff-swipe", "image-diff-overlay", "image-diff-difference", "image-diff-added",
    ]

    /// The mode a fresh image diff view starts in.
    static var initialImageMode: ImageDiffMode {
#if DEBUG
        guard isCaptureInstance else { return .sideBySide }
        switch requestedMode {
        case "image-diff-swipe": return .swipe
        case "image-diff-overlay": return .overlay
        case "image-diff-difference": return .difference
        default: return .sideBySide
        }
#else
        .sideBySide
#endif
    }

#if DEBUG
    /// Set by `open` before the tab exists, so the view's first state already has the mode.
    private static var requestedMode: String?

    /// Only an instance capture.sh launched on a demo profile may react; another Debug
    /// instance also receives the distributed capture notification and must ignore it.
    private static var isCaptureInstance: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["ALAS_DESIGN_CAPTURE"] == "1" && env["ALAS_APP_SUPPORT_DIR"] != nil
    }

    static func open(_ target: String, state: AppState) {
        guard isCaptureInstance else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty || state.selectedWorktreeId.flatMap({ state.worktree(withId: $0) }) == nil {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let worktree = state.selectedWorktreeId.flatMap({ state.worktree(withId: $0) }) else { return }
            requestedMode = target
            let path = switch target {
            case "diff-file": "src/billing/Invoice.swift"
            case "image-diff-added": "docs/new-chart.png"
            default: "docs/usage-chart.png"
            }
            state.openDiffTab(forFileInWorktree: worktree, relativePath: path)
        }
    }
#endif
}
