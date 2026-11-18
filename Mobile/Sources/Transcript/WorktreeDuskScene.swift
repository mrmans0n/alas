import SwiftUI

/// A cabin above the water, with the same flocking motion as the Mac's forest.
struct WorktreeDuskScene: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var flight = DuskFlight()
    @State private var began = Date.now

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { frame in
            Canvas(opaque: true) { context, size in
                guard size.width > 0, size.height > 0 else { return }
                let time = reduceMotion ? 0 : max(0, frame.date.timeIntervalSince(began))
                var context = context
                let scene = DuskLandscape(size: size, time: time)
                scene.drawSky(in: &context)
                if reduceMotion {
                    scene.drawRestingFlock(in: &context)
                } else {
                    flight.draw(in: &context, size: size, time: time)
                }
                scene.drawShore(in: &context)
            }
        }
    }
}

private final class DuskFlight {
    private var flock = Boids()
    private var previousTime: Double?
    private var previousSize: CGSize = .zero

    func draw(in context: inout GraphicsContext, size: CGSize, time: Double) {
        let orbit = min(size.width, size.height)
        if size != previousSize {
            flock.seed(count: 26, around: .init(size.width * 0.48, size.height * 0.25),
                       spread: .init(orbit * 0.13, orbit * 0.06))
            previousSize = size
        }
        let delta = min(max(time - (previousTime ?? time), 0), 1.0 / 24)
        previousTime = time
        let target = Boids.V(
            size.width * 0.5 + cos(time * 0.57) * orbit * 0.25,
            size.height * 0.24 + sin(time * 0.82) * orbit * 0.11
        )
        flock.step(dt: delta, goal: target, goalPull: 158, flee: nil, speed: 32...92)
        flock.drawWings(in: &context, color: Color(red: 0.84, green: 0.83, blue: 0.90), size: 2)
    }
}

private struct DuskLandscape {
    let size: CGSize
    let time: Double

    private let sky = Color(red: 0.046, green: 0.071, blue: 0.16)
    private let violet = Color(red: 0.23, green: 0.25, blue: 0.38)
    private let dusk = Color(red: 0.79, green: 0.48, blue: 0.40)
    private let blue = Color(red: 0.14, green: 0.26, blue: 0.34)
    private let teal = Color(red: 0.08, green: 0.19, blue: 0.22)
    private let foreground = Color(red: 0.045, green: 0.11, blue: 0.15)
    private let amber = Color(red: 1, green: 0.73, blue: 0.36)
    private let moonlight = Color(red: 1, green: 0.88, blue: 0.75)
    private var unit: CGFloat { min(size.width, size.height) }

    func drawSky(in context: inout GraphicsContext) {
        let bounds = Path(CGRect(origin: .zero, size: size))
        context.fill(bounds, with: .linearGradient(
            Gradient(stops: [.init(color: sky, location: 0), .init(color: violet, location: 0.36),
                             .init(color: dusk, location: 0.62), .init(color: blue, location: 0.73),
                             .init(color: foreground, location: 1)]),
            startPoint: .zero, endPoint: point(0, 1)
        ))

        let moon = point(0.78, 0.18)
        glow(in: &context, at: moon, radius: unit * 0.21, color: moonlight.opacity(0.24))
        dot(in: &context, at: moon, radius: unit * 0.032, color: moonlight)
        for index in 0..<48 {
            let seed = Double(index)
            let star = point(hash(seed, 1), hash(seed, 2) * 0.43)
            let brightness = 0.29 + sin(time * 0.7 + seed) * 0.16
            dot(in: &context, at: star, radius: 0.4 + hash(seed, 3) * 0.65, color: moonlight.opacity(brightness))
        }
    }

    func drawRestingFlock(in context: inout GraphicsContext) {
        var wings = Path()
        for index in 0..<19 {
            let seed = Double(index)
            let bird = point(0.34 + hash(seed, 4) * 0.31, 0.24 + hash(seed, 5) * 0.095)
            let lift = 0.9 + hash(seed, 6) * 1.6
            wings.move(to: CGPoint(x: bird.x - 3, y: bird.y - lift))
            wings.addLine(to: bird)
            wings.addLine(to: CGPoint(x: bird.x + 3, y: bird.y - lift))
        }
        context.stroke(wings, with: .color(moonlight.opacity(0.64)), style: .init(lineWidth: 0.9, lineCap: .round))
    }

    func drawShore(in context: inout GraphicsContext) {
        for (index, layer) in [blue, teal, foreground].enumerated() {
            let depth = Double(index)
            let ridge = Boids.ridge(size: size, base: 0.65 + depth * 0.097, amp: 0.065 + depth * 0.025,
                                   drift: time * (1 + depth * 1.4), seed: depth * 1.7)
            context.fill(ridge, with: .color(layer))
        }

        for index in 0..<16 {
            let seed = Double(index)
            let y = 0.716 + hash(seed, 7) * 0.076
            let x = 0.17 + hash(seed, 8) * 0.41
            let width = (0.02 + hash(seed, 9) * 0.15) * (0.9 + 0.1 * sin(time * 0.65 + seed))
            var ripple = Path()
            ripple.move(to: point(x, y))
            ripple.addLine(to: point(x + width, y))
            context.stroke(ripple, with: .color(moonlight.opacity(0.11)), style: .init(lineWidth: 1, lineCap: .round))
        }

        // The cabin and pines share a small promontory above the lake.
        let hill = point(0.75, 0.78)
        let shore = Path { path in
            path.move(to: point(0.46, 0.92))
            path.addQuadCurve(to: hill, control: point(0.63, 0.79))
            path.addQuadCurve(to: point(1, 0.73), control: point(0.87, 0.77))
            path.addLine(to: point(1, 1))
            path.addLine(to: point(0.46, 1))
            path.closeSubpath()
        }
        context.fill(shore, with: .color(foreground))
        drawCabin(in: &context, at: hill)

        for (x, y, height) in [(0.88, 0.765, 0.15), (0.96, 0.747, 0.2), (0.59, 0.851, 0.09), (0.53, 0.89, 0.06)] {
            drawPine(in: &context, base: point(x, y), height: unit * height)
        }
        for index in 0..<21 {
            let seed = Double(index)
            let x = 0.1 + hash(seed, 10) * 0.85 + sin(time * 0.45 + seed) * 0.026
            let y = 0.67 + hash(seed, 11) * 0.26 + cos(time * 0.5 + seed) * 0.02
            let brightness = 0.16 + pow(0.5 + 0.5 * sin(time * 1.1 + seed * 2.3), 3) * 0.55
            let center = point(x, y)
            let color = amber.opacity(brightness)
            glow(in: &context, at: center, radius: 8, color: color.opacity(0.55))
            dot(in: &context, at: center, radius: 1.15, color: color)
        }
    }

    private func drawCabin(in context: inout GraphicsContext, at base: CGPoint) {
        let width = unit * 0.135
        let height = width * 0.72
        let left = base.x - width * 0.5
        let top = base.y - height
        let roof = Path { path in
            path.move(to: CGPoint(x: left - width * 0.14, y: top + height * 0.12))
            path.addLine(to: CGPoint(x: base.x, y: top - height * 0.69))
            path.addLine(to: CGPoint(x: left + width * 1.14, y: top + height * 0.12))
            path.closeSubpath()
        }
        context.fill(Path(CGRect(x: left, y: top, width: width, height: height)), with: .color(blue))
        context.fill(roof, with: .color(foreground))
        let window = CGRect(x: left + width * 0.21, y: top + height * 0.31, width: width * 0.22, height: height * 0.35)
        let windowCenter = CGPoint(x: window.midX, y: window.midY)
        glow(in: &context, at: windowCenter, radius: width * 0.65, color: amber.opacity(0.3))
        context.fill(Path(roundedRect: window, cornerRadius: 1), with: .color(amber))
        context.fill(Path(CGRect(x: window.midX - 0.5, y: window.minY, width: 1, height: window.height)), with: .color(blue))
        context.fill(Path(CGRect(x: left + width * 0.6, y: top + height * 0.42,
                                 width: width * 0.2, height: height * 0.58)), with: .color(foreground))
    }

    private func drawPine(in context: inout GraphicsContext, base: CGPoint, height: CGFloat) {
        var pine = Path()
        for tier in 0..<3 {
            let index = CGFloat(tier)
            let bottom = base.y - index * height * 0.22
            let half = height * (0.25 - index * 0.052)
            pine.move(to: CGPoint(x: base.x - half, y: bottom))
            pine.addLine(to: CGPoint(x: base.x, y: bottom - height * 0.56))
            pine.addLine(to: CGPoint(x: base.x + half, y: bottom))
            pine.closeSubpath()
        }
        context.fill(pine, with: .color(foreground))
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: size.width * x, y: size.height * y)
    }

    private func dot(in context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, color: Color) {
        context.fill(disk(at: point, radius: radius), with: .color(color))
    }

    private func glow(in context: inout GraphicsContext, at point: CGPoint, radius: CGFloat, color: Color) {
        context.fill(disk(at: point, radius: radius), with: .radialGradient(
            Gradient(colors: [color, .clear]), center: point, startRadius: 0, endRadius: radius))
    }

    private func disk(at point: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
    }

    private func hash(_ value: Double, _ seed: Double) -> Double {
        let noise = sin(value * 12.9898 + seed * 78.233) * 43758.5453
        return noise - floor(noise)
    }
}
