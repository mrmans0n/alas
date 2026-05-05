import AppKit
import Foundation

/// STUB: real implementation lands in Task 12 (load + highlight).
///
/// Holds a weak reference to the attached `CodeTextView` so the SwiftUI
/// representable can drive lifecycle (attach/update/detach) without leaking
/// the view back into AppState.
@MainActor
final class CodeEditorCoordinator {
    let appState: AppState
    private weak var textView: CodeTextView?

    init(appState: AppState) {
        self.appState = appState
    }

    func attach(textView: CodeTextView, worktreeRoot: URL, relativePath: String, theme: Theme) {
        self.textView = textView
    }

    func updateIfNeeded(worktreeRoot: URL, relativePath: String, theme: Theme) {}

    func detach() {}
}
