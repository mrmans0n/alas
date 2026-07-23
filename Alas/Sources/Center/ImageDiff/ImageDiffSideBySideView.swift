import AppKit
import SwiftUI

/// Pure value type for the side-by-side pan/zoom state. Lives here so
/// the parent can `@State` one of these and pass `Binding` into both
/// panes — keeping them visually in sync without any extra plumbing.
struct ImageDiffTransform: Equatable {
    var scale: CGFloat
    var offset: CGSize

    init(scale: CGFloat = 1.0, offset: CGSize = .zero) {
        self.scale = scale
        self.offset = offset
    }

    static let minScale: CGFloat = 1.0
    static let maxScale: CGFloat = 10.0

    mutating func reset() {
        self = .init()
    }

    /// `delta` is a small per-tick zoom amount (e.g. 0.05). Positive
    /// zooms in.
    mutating func applyZoomDelta(_ delta: CGFloat) {
        scale = min(Self.maxScale, max(Self.minScale, scale + delta))
    }

    mutating func applyPanDelta(dx: CGFloat, dy: CGFloat) {
        offset.width += dx
        offset.height += dy
    }
}

struct ImageDiffSideBySideView: View {
    let before: ImageDiffSide
    let after: ImageDiffSide
    let beforeLabel: String
    let afterLabel: String
    @Binding var transform: ImageDiffTransform
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let stackVertically = proxy.size.width < 600
            let panes = Group {
                pane(side: before, label: beforeLabel, missingText: "No before")
                divider(stack: stackVertically)
                pane(side: after,  label: afterLabel,  missingText: "No after")
            }
            if stackVertically {
                VStack(spacing: 0) { panes }
            } else {
                HStack(spacing: 0) { panes }
            }
        }
        .overlay(
            ScrollEventCapturingView { dx, dy, isCommand in
                if isCommand {
                    transform.applyZoomDelta((dy / 50.0))
                } else {
                    transform.applyPanDelta(dx: dx, dy: dy)
                }
            }
        )
        .onTapGesture(count: 2) { transform.reset() }
    }

    @ViewBuilder
    private func pane(side: ImageDiffSide, label: String, missingText: String) -> some View {
        ZStack {
            ImageCheckerboardBackground()
            switch side {
            case .image(let image, _):
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(transform.scale)
                    .offset(transform.offset)
            case .missing, .failed:
                if let message = Self.placeholderMessage(for: side, missingText: missingText) {
                    placeholder(message)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.5))
                .cornerRadius(3)
                .padding(6)
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func placeholderMessage(for side: ImageDiffSide, missingText: String) -> String? {
        switch side {
        case .image:
            nil
        case .missing:
            missingText
        case .failed(let failure):
            failure.message
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg-faint"))
            .padding(16)
            .background(.black.opacity(0.25))
            .cornerRadius(6)
    }

    @ViewBuilder
    private func divider(stack: Bool) -> some View {
        if stack {
            Divider().background(theme.color("line"))
        } else {
            Divider().background(theme.color("line"))
                .frame(width: 1)
        }
    }
}
