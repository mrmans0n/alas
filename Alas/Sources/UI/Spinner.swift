import AppKit
import SwiftUI

struct Spinner: View {
    var lineWidth: CGFloat = 2
    var duration: Double = 0.8
    var color: Color?

    @Environment(\.theme) private var theme

    var body: some View {
        SpinnerRepresentable(
            lineWidth: lineWidth,
            duration: duration,
            color: NSColor(color ?? theme.color("accent"))
        )
    }
}

private struct SpinnerRepresentable: NSViewRepresentable {
    let lineWidth: CGFloat
    let duration: Double
    let color: NSColor

    func makeNSView(context: Context) -> SpinnerAnimationView {
        SpinnerAnimationView(lineWidth: lineWidth, duration: duration, color: color)
    }

    func updateNSView(_ view: SpinnerAnimationView, context: Context) {
        view.update(lineWidth: lineWidth, duration: duration, color: color)
    }
}

@MainActor
final class SpinnerAnimationView: NSView {
    static let rotationAnimationKey = "rotation"

    let spinnerLayer = CAShapeLayer()
    private var animationDuration: Double

    init(lineWidth: CGFloat, duration: Double, color: NSColor) {
        animationDuration = duration
        super.init(frame: .zero)
        wantsLayer = true
        spinnerLayer.fillColor = nil
        spinnerLayer.lineCap = .round
        spinnerLayer.strokeEnd = 0.75
        layer?.addSublayer(spinnerLayer)
        update(lineWidth: lineWidth, duration: duration, color: color)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinnerLayer.frame = bounds
        spinnerLayer.path = CGPath(
            ellipseIn: bounds.insetBy(dx: spinnerLayer.lineWidth / 2, dy: spinnerLayer.lineWidth / 2),
            transform: nil
        )
        CATransaction.commit()
    }

    func update(lineWidth: CGFloat, duration: Double, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinnerLayer.lineWidth = lineWidth
        spinnerLayer.strokeColor = color.cgColor
        CATransaction.commit()

        guard spinnerLayer.animation(forKey: Self.rotationAnimationKey) == nil
                || animationDuration != duration
        else { return }
        animationDuration = duration
        let animation = CABasicAnimation(keyPath: "transform.rotation")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = duration
        animation.repeatCount = .infinity
        spinnerLayer.add(animation, forKey: Self.rotationAnimationKey)
    }
}
