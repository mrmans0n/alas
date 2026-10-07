import AppKit
import SwiftUI

/// A sent symbol mention in the transcript: the composer badge's code-token
/// look. Click opens the symbol in the editor at the range that was sent;
/// hover shows what was sent, or the code now.
struct ACPSymbolBadge: View {
    let target: ACPSymbolReference.Target
    let snapshot: ACPSymbolSnapshot?
    /// Where the preview reads files; without it the badge has no preview.
    let root: URL?
    let typography: ACPChatTypography
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false
    @State private var showsPreview = false

    private var containerText: String { target.container.map { $0 + "." } ?? "" }
    private var nameText: String { target.kind.isCallable ? target.name + "()" : target.name }
    private var countText: String? {
        target.includeCode
            ? ACPSymbolReference.Target.lineCountText(for: snapshot?.lineRange ?? target.lineRange) : nil
    }

    private var label: AttributedString {
        var container = AttributedString(containerText)
        container.foregroundColor = Color(nsColor: SymbolKind.class.badgeLabelColor)
        var name = AttributedString(nameText)
        name.foregroundColor = Color(nsColor: target.kind.badgeLabelColor)
        return container + name
    }

    var body: some View {
        Button {
            if let url = ACPSymbolReference.openURL(for: target, snapshot: snapshot) { openURL(url) }
        } label: {
            pill
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onDisappear {
            isHovering = false
            showsPreview = false
        }
        .task(id: isHovering) {
            guard isHovering, root != nil else {
                showsPreview = false
                return
            }
            try? await Task.sleep(for: .seconds(ACPImageChipHoverController.hoverDelay))
            if !Task.isCancelled { showsPreview = true }
        }
        .popover(isPresented: $showsPreview, arrowEdge: .bottom) {
            if let root {
                ACPSymbolSentHoverView(target: target, snapshot: snapshot, root: root,
                                       typography: typography, theme: theme)
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 0) {
            if target.includeCode {
                Rectangle().fill(Color(nsColor: .controlAccentColor)).frame(width: 2)
            }
            HStack(spacing: 5) {
                Text(target.kind.badgeLetter)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color(nsColor: target.kind.badgeLabelColor))
                    .frame(width: 13, height: 13)
                    .background(Color(nsColor: target.kind.badgeBackground), in: RoundedRectangle(cornerRadius: 3))
                Text(label)
                    .font(Font(ACPMentionChipMetrics.labelFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 4)
            .padding(.trailing, 6)
            if let countText {
                HStack(spacing: 0) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                    Text(countText)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        .padding(.horizontal, 5)
                }
                .background(Color(nsColor: ACPSymbolChipCell.countFill))
            }
        }
        .frame(height: 20)
        .background(Color(nsColor: ACPSymbolChipCell.pillFill))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5).strokeBorder(
                target.includeCode
                    ? Color(nsColor: NSColor.controlAccentColor.withAlphaComponent(0.6))
                    : Color(nsColor: .separatorColor),
                lineWidth: 0.75)
        )
        .contentShape(Rectangle())
    }
}
