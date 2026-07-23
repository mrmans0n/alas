import AppKit
import SwiftUI

struct ImageDiffView: View {
    let pair: ImageDiffPair
    let relativePath: String
    let onOpenFile: (() -> Void)?

    @State private var presentation = ImageDiffPresentationState()
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.color("bg-1"))
        .onAppear { presentation.snapToApplicableMode(for: pair) }
        .onChange(of: presentation.mode) { _, _ in
            // Bouncing back when user attempts a disabled mode is enforced
            // by the segmented control disabling itself; this is a belt-
            // and-suspenders check.
            presentation.snapToApplicableMode(for: pair)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text((relativePath as NSString).lastPathComponent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.color("fg"))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((relativePath as NSString).deletingLastPathComponent)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            if pair.kind == .renamed, let old = pair.oldPath {
                pathChangeChip(kind: "RENAMED", old: old, new: relativePath)
            }
            if pair.kind == .copied, let old = pair.oldPath {
                pathChangeChip(kind: "COPIED", old: old, new: relativePath)
            }
            ImageDiffControls(pair: pair, state: presentation)
            if let onOpenFile {
                AlasButton(title: "Open File", style: .subtle, action: onOpenFile)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func pathChangeChip(kind: String, old: String, new: String) -> some View {
        let oldName = (old as NSString).lastPathComponent
        let newName = (new as NSString).lastPathComponent
        Text("\(kind) \(oldName) → \(newName)")
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(theme.color("info").opacity(0.18))
            .foregroundColor(theme.color("info"))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var content: some View {
        ImageDiffComparisonContent(pair: pair, state: presentation)
    }
}
