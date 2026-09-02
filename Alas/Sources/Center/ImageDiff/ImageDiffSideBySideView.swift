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

struct ImageDiffAnnotationGeometry {
    let imageSize: CGSize
    let viewportSize: CGSize
    let transform: ImageDiffTransform

    private var displayedFrame: CGRect? {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        let fitScale = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        let size = CGSize(
            width: imageSize.width * fitScale * transform.scale,
            height: imageSize.height * fitScale * transform.scale
        )
        return CGRect(
            x: (viewportSize.width - size.width) / 2 + transform.offset.width,
            y: (viewportSize.height - size.height) / 2 + transform.offset.height,
            width: size.width,
            height: size.height
        )
    }

    func normalizedPoint(at point: CGPoint) -> CGPoint? {
        guard let frame = displayedFrame, frame.contains(point) else { return nil }
        return CGPoint(
            x: (point.x - frame.minX) / frame.width,
            y: (point.y - frame.minY) / frame.height
        )
    }

    func displayPoint(normalizedX: Double, normalizedY: Double) -> CGPoint? {
        guard let frame = displayedFrame,
              (0...1).contains(normalizedX), (0...1).contains(normalizedY) else { return nil }
        return CGPoint(
            x: frame.minX + frame.width * normalizedX,
            y: frame.minY + frame.height * normalizedY
        )
    }
}

struct ImageDiffAnnotationMarker: Identifiable {
    let id: String
    let number: Int
    let normalizedX: Double
    let normalizedY: Double
}

struct ImageDiffAnnotationPresentation {
    let markersBySide: [DiffReviewInlineFeedbackSide: [ImageDiffAnnotationMarker]]
    let pendingPointBySide: [DiffReviewInlineFeedbackSide: CGPoint]
    let focusedMarkerID: String?
    let onPointSelected: (DiffReviewInlineFeedbackSide, CGPoint) -> Void
    let onMarkerSelected: (String) -> Void

    func markers(for side: DiffReviewInlineFeedbackSide) -> [ImageDiffAnnotationMarker] {
        markersBySide[side] ?? []
    }

    func pendingPoint(for side: DiffReviewInlineFeedbackSide) -> CGPoint? {
        pendingPointBySide[side]
    }
}

struct ImageDiffSideBySideView: View {
    let before: ImageDiffSide
    let after: ImageDiffSide
    let beforeLabel: String
    let afterLabel: String
    @Binding var transform: ImageDiffTransform
    var annotation: ImageDiffAnnotationPresentation? = nil
    @Environment(\.theme) private var theme
    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let stackVertically = proxy.size.width < 600
            let panes = Group {
                pane(side: before, role: .old, label: beforeLabel, missingText: "No before")
                divider(stack: stackVertically)
                pane(side: after, role: .new, label: afterLabel, missingText: "No after")
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
                }
            }
        )
        .simultaneousGesture(panGesture)
    }

    @ViewBuilder
    private func pane(
        side: ImageDiffSide,
        role: DiffReviewInlineFeedbackSide,
        label: String,
        missingText: String
    ) -> some View {
        GeometryReader { proxy in
            ZStack {
                ZStack {
                    ImageCheckerboardBackground()
                    switch side {
                    case .image(let image, _):
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(transform.scale)
                            .offset(Self.displayOffset(committed: transform.offset, translation: dragTranslation))
                    case .missing, .failed:
                        if let message = Self.placeholderMessage(for: side, missingText: missingText) {
                            placeholder(message)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { _ in transform.reset() }
                        .exclusively(before: SpatialTapGesture().onEnded { value in
                            guard annotation != nil, case .image(let image, _) = side,
                                  let point = geometry(imageSize: image.size, viewportSize: proxy.size)
                                    .normalizedPoint(at: value.location) else { return }
                            annotation?.onPointSelected(role, point)
                        })
                )
                if annotation != nil, case .image(let image, _) = side {
                    markers(side: role, imageSize: image.size, viewportSize: proxy.size)
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
                .allowsHitTesting(false)
        }
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func markers(side: DiffReviewInlineFeedbackSide, imageSize: CGSize, viewportSize: CGSize) -> some View {
        let geometry = geometry(imageSize: imageSize, viewportSize: viewportSize)
        ForEach(annotation?.markers(for: side) ?? []) { marker in
            if let point = geometry.displayPoint(normalizedX: marker.normalizedX, normalizedY: marker.normalizedY) {
                Button { annotation?.onMarkerSelected(marker.id) } label: {
                    Text("\(marker.number)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(annotation?.focusedMarkerID == marker.id ? Color.accentColor : Color.red)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .position(point)
                .accessibilityLabel("Image comment \(marker.number)")
            }
        }
        if let pending = annotation?.pendingPoint(for: side),
           let point = geometry.displayPoint(normalizedX: pending.x, normalizedY: pending.y) {
            Circle().fill(Color.accentColor).overlay(Circle().stroke(.white, lineWidth: 1))
                .frame(width: 14, height: 14).position(point)
                .accessibilityLabel("New image comment")
        }
    }

    private func geometry(imageSize: CGSize, viewportSize: CGSize) -> ImageDiffAnnotationGeometry {
        ImageDiffAnnotationGeometry(
            imageSize: imageSize,
            viewportSize: viewportSize,
            transform: .init(
                scale: transform.scale,
                offset: Self.displayOffset(committed: transform.offset, translation: dragTranslation)
            )
        )
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

    nonisolated static func displayOffset(
        committed: CGSize,
        translation: CGSize
    ) -> CGSize {
        CGSize(
            width: committed.width + translation.width,
            height: committed.height + translation.height
        )
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

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($dragTranslation) { value, translation, _ in
                translation = value.translation
            }
            .onEnded { value in
                transform.applyPanDelta(
                    dx: value.translation.width,
                    dy: value.translation.height
                )
            }
    }
}
