import CoreGraphics

enum MermaidDiagramLayout {
    static func fittedSize(
        intrinsic: CGSize,
        availableWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        guard intrinsic.width > 0, intrinsic.height > 0 else { return .zero }
        let scale = min(1, availableWidth / intrinsic.width, maxHeight / intrinsic.height)
        return CGSize(width: intrinsic.width * scale, height: intrinsic.height * scale)
    }

    static func actualSizeScale(intrinsic: CGSize, fitted: CGSize) -> CGFloat {
        guard intrinsic.width > 0,
              intrinsic.height > 0,
              fitted.width > 0,
              fitted.height > 0
        else { return 1 }

        let scale = max(
            intrinsic.width / fitted.width,
            intrinsic.height / fitted.height
        )
        return scale.isFinite && scale > 0 ? scale : 1
    }
}

struct MermaidRenderRequestState {
    private(set) var currentKey: MermaidRenderKey?
    private(set) var outcome: MermaidRenderOutcome?

    mutating func begin(_ key: MermaidRenderKey) {
        currentKey = key
        outcome = nil
    }

    mutating func apply(_ outcome: MermaidRenderOutcome, for key: MermaidRenderKey) {
        guard key == currentKey else { return }
        self.outcome = outcome
    }
}

struct MermaidZoomState: Equatable {
    static let minimumScale: CGFloat = 0.25
    static let maximumScale: CGFloat = 8

    private(set) var scale: CGFloat = 1
    private(set) var translation: CGSize = .zero

    mutating func zoom(by factor: CGFloat) {
        scale = scale(adding: factor)
    }

    mutating func setScale(_ scale: CGFloat) {
        guard scale.isFinite else { return }
        self.scale = Self.clamped(scale)
    }

    mutating func setActualSize(_ scale: CGFloat) {
        guard scale.isFinite, scale > 0 else { return }
        self.scale = max(Self.minimumScale, scale)
    }

    mutating func translate(by delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        translation.width += delta.width
        translation.height += delta.height
    }

    mutating func resetToFit() {
        scale = 1
        translation = .zero
    }

    func scale(adding factor: CGFloat) -> CGFloat {
        guard factor.isFinite, factor > 0 else { return scale }
        let nextScale = scale * factor
        guard nextScale.isFinite else { return scale }
        if scale > Self.maximumScale {
            return max(Self.minimumScale, nextScale)
        }
        return Self.clamped(nextScale)
    }

    private static func clamped(_ scale: CGFloat) -> CGFloat {
        min(maximumScale, max(minimumScale, scale))
    }
}
