import AppKit
import SwiftUI

struct ImageDiffView: View {
    @Environment(\.designScale) private var scale
    let pair: ImageDiffPair
    let relativePath: String
    let onOpenFile: (() -> Void)?
    let sourceBadge: String?
    let onRetry: (() -> Void)?

    @State private var presentation = ImageDiffPresentationState()
    @StateObject private var copyFeedback = CopyFeedbackState()
    @Environment(\.theme) private var theme

    init(
        pair: ImageDiffPair,
        relativePath: String,
        onOpenFile: (() -> Void)?,
        sourceBadge: String? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.pair = pair
        self.relativePath = relativePath
        self.onOpenFile = onOpenFile
        self.sourceBadge = sourceBadge
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.color("bg-1"))
        .copyFeedbackOverlay(message: copyFeedback.message)
        .onAppear {
            presentation.updateDisplayedPair(pair, identity: pairPresentationIdentity)
        }
        .onChange(of: pairPresentationIdentity) { _, _ in
            presentation.updateDisplayedPair(pair, identity: pairPresentationIdentity)
        }
        .onChange(of: presentation.mode) { _, _ in
            // Bouncing back when user attempts a disabled mode is enforced
            // by the segmented control disabling itself; this is a belt-
            // and-suspenders check.
            presentation.snapToApplicableMode(for: pair)
        }
    }

    private var pairPresentationIdentity: ImageDiffPairPresentationIdentity {
        ImageDiffPairPresentationIdentity(pair: pair, relativePath: relativePath)
    }

    private var header: some View {
        HStack(spacing: scale.space[3]) {
            Button {
                copyFeedback.copy(relativePath)
            } label: {
                HStack(spacing: scale.space[3]) {
                    Text((relativePath as NSString).lastPathComponent)
                        .font(scale.meta.font(design: .monospaced))
                        .foregroundColor(theme.color("fg"))
                    if let sourceBadge {
                        Text(sourceBadge)
                            .font(scale.caption.font(weight: .semibold))
                            .padding(.horizontal, scale.space[1])
                            .padding(.vertical, scale.space[0])
                            .background(theme.color("accent").opacity(0.16))
                            .foregroundColor(theme.color("accent"))
                            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                    }
                    Text("·").foregroundColor(theme.color("fg-faint"))
                    Text((relativePath as NSString).deletingLastPathComponent)
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Copy path")
            .accessibilityLabel("Copy \(relativePath)")
            if pair.kind == .renamed, let old = pair.oldPath {
                pathChangeChip(kind: "RENAMED", old: old, new: relativePath)
            }
            if pair.kind == .copied, let old = pair.oldPath {
                pathChangeChip(kind: "COPIED", old: old, new: relativePath)
            }
            ImageDiffControls(pair: pair, state: presentation)
            if pair.hasFailure, let onRetry {
                AlasButton(title: "Retry", style: .subtle, action: onRetry)
                    .accessibilityIdentifier("image-diff-retry")
            }
            if let onOpenFile {
                AlasButton(title: "Open File", style: .subtle, action: onOpenFile)
            }
        }
        .padding(.horizontal, scale.space[4]).padding(.vertical, scale.space[3])
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func pathChangeChip(kind: String, old: String, new: String) -> some View {
        let oldName = (old as NSString).lastPathComponent
        let newName = (new as NSString).lastPathComponent
        Text("\(kind) \(oldName) → \(newName)")
            .font(scale.caption.font(weight: .semibold))
            .padding(.horizontal, scale.space[1]).padding(.vertical, scale.space[0])
            .background(theme.color("info").opacity(0.18))
            .foregroundColor(theme.color("info"))
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
    }

    private var content: some View {
        ImageDiffComparisonContent(pair: pair, state: presentation)
    }
}
