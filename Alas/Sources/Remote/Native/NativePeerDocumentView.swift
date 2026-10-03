import AppKit
import SwiftUI

/// A peer file or diff opened from the peer right pane. It covers the
/// transcript until closed; the session stays subscribed underneath.
struct NativePeerDocumentView: View {
    let document: NativePeerWorkspace.Document
    let content: NativePeerWorkspace.Load<NativePeerWorkspace.DocumentContent>
    var codeFontFamily: String = ""
    var codeFontSize: CGFloat = 13
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @State private var displayModel: DiffDisplayModel?
    @State private var layoutMode: DiffLayoutMode = .split
    @State private var wrapLines = false
    @State private var showWhitespace = false

    var body: some View {
        VStack(spacing: 0) {
            header
            documentBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.color("bg-1"))
        .task(id: content) { await buildDisplayModel() }
    }

    private var badge: String {
        switch document {
        case .diff(_, .staged): "staged"
        case .diff(_, .unstaged): "unstaged"
        case .diff(_, nil): "branch"
        case .commitDiff(_, let sha): String(sha.prefix(7))
        case .file: "peer"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text((document.path as NSString).lastPathComponent)
                .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize))
                .foregroundColor(theme.color("fg"))
            Text(badge)
                .font(.system(size: 9.5, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(theme.color("accent").opacity(0.16))
                .foregroundColor(theme.color("accent"))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((document.path as NSString).deletingLastPathComponent)
                .font(.system(size: codeFontSize - 1.5))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            ToolbarBtn(icon: "x", tooltip: "Back to session", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private var documentBody: some View {
        switch content {
        case .idle, .loading:
            Spinner()
                .frame(width: 16, height: 16)
                .padding()
        case .failed(let message):
            note(message, color: "del")
        case .loaded(.text(let text, let truncated)):
            if truncated { note("Showing the start of this file; the peer cut off the rest.") }
            ReadonlyTextView(
                text: text,
                font: CenterTypography.resolveCodeFont(family: codeFontFamily, size: codeFontSize),
                textColor: NSColor(theme.color("fg")),
                backgroundColor: .clear
            )
        case .loaded(.diff(let diff, let truncated)):
            if truncated { note("The peer cut off this diff.") }
            if diff.hunks.isEmpty {
                note(diff.metadataSummary ?? "No changes for \(document.path)")
            } else if let displayModel {
                DiffPaneView(
                    model: displayModel,
                    fileExtension: LanguageRegistry.highlighterExtension(forPath: document.path),
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

    private func note(_ text: String, color: String = "fg-dim") -> some View {
        Text(text)
            .font(CenterTypography.codeFont(family: codeFontFamily, size: codeFontSize - 2))
            .foregroundColor(theme.color(color))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.color("bg-2"))
    }

    private func buildDisplayModel() async {
        guard case .loaded(.diff(let diff, _)) = content, !diff.hunks.isEmpty else {
            displayModel = nil
            return
        }
        let path = document.path
        let model = await Task.detached(priority: .userInitiated) {
            DiffDisplayModelBuilder.build(diff: diff, filePath: path)
        }.value
        guard !Task.isCancelled else { return }
        displayModel = model
    }
}
