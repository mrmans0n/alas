import SwiftUI

/// Dusk sky with a starling murmuration, drawn behind the first-run screen.
/// Birds are classic boids chasing a wandering attractor and scattering away
/// from the cursor.
struct WelcomeSky: View {
    let flock: WelcomeFlock
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                flock.step(to: t, in: size)
                flock.draw(in: &ctx, size: size, time: t)
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Your new agentic IDE. Every agent. Every worktree. One window.")
    }
}

final class WelcomeFlock {
    private typealias V = SIMD2<Double>

    private struct Bird {
        var p: V
        var v: V
        var phase: Double
        var layer: Int
    }

    private struct Star {
        var p: V
        var size: Double
        var twinkle: Double
    }

    /// Cursor position in the sky's coordinate space; birds flee from it.
    var cursor: CGPoint?
    /// Size of the call-to-action button, centered and pushed down by
    /// `buttonOffset`. The scene is drawn again behind it, blurred, so birds
    /// smear as they pass, and the headline is laid out above it.
    var buttonSize: CGSize?
    static let buttonOffset: CGFloat = 70
    static let buttonCornerRadius: CGFloat = 7

    private var birds: [Bird] = []
    private var stars: [Star] = []
    private var lastTime: Double?
    private var size = CGSize.zero

    private static let birdCount = 320
    private static let layerScale: [Double] = [0.75, 1.0, 1.3]

    func step(to t: Double, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if birds.isEmpty || self.size != size { seed(size) }
        let dt = min(max(t - (lastTime ?? t), 0), 1.0 / 30)
        lastTime = t
        guard dt > 0 else { return }

        let w = size.width, h = size.height
        // Lissajous attractor sweeps the flock across the sky.
        let goal = V(w * (0.5 + 0.34 * sin(t * 0.13) * cos(t * 0.051)),
                     h * (0.5 + 0.14 * sin(t * 0.19 + 1.3)))
        let mouse = cursor.map { V($0.x, $0.y) }

        // ponytail: O(n²) neighbor scan, fine at ~300 birds; add a grid if the count grows.
        var next = birds
        for i in birds.indices {
            let b = birds[i]
            var align = V.zero, center = V.zero, separate = V.zero
            var neighbors = 0.0
            for j in birds.indices where j != i {
                let d = birds[j].p - b.p
                let d2 = (d * d).sum()
                guard d2 < 50 * 50 else { continue }
                neighbors += 1
                align += birds[j].v
                center += d
                if d2 < 14 * 14 { separate -= d / max(d2, 1) }
            }
            var a = V.zero
            if neighbors > 0 {
                a += (align / neighbors - b.v) * 1.1
                a += center / neighbors * 0.9
            }
            a += separate * 1100
            let toGoal = goal - b.p
            a += toGoal / max(length(toGoal), 1) * 55
            if let mouse {
                let away = b.p - mouse
                let dist = length(away)
                if dist < 160 { a += away / max(dist, 1) * 1400 * (1 - dist / 160) }
            }

            var v = b.v + a * dt
            let speed = length(v)
            v = v / max(speed, 0.001) * min(max(speed, 70), 170)
            next[i].v = v
            next[i].p = b.p + v * dt
            next[i].phase += dt * (9 + speed / 25)
        }
        birds = next
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        drawScene(in: &ctx, size: size, time: t)
        guard let buttonSize else { return }
        let glass = Path(roundedRect: buttonRect(buttonSize, in: size), cornerRadius: Self.buttonCornerRadius)
        ctx.drawLayer { clipped in
            clipped.clip(to: glass)
            clipped.drawLayer { blurred in
                blurred.addFilter(.blur(radius: 14))
                drawScene(in: &blurred, size: size, time: t)
            }
            clipped.fill(glass, with: .color(.white.opacity(0.12)))
        }
    }

    private func drawScene(in ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = size.width, h = size.height
        let rect = CGRect(origin: .zero, size: size)

        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.03, green: 0.04, blue: 0.13), location: 0),
                .init(color: Color(red: 0.13, green: 0.12, blue: 0.36), location: 0.35),
                .init(color: Color(red: 0.45, green: 0.25, blue: 0.50), location: 0.60),
                .init(color: Color(red: 0.90, green: 0.45, blue: 0.40), location: 0.80),
                .init(color: Color(red: 0.99, green: 0.72, blue: 0.43), location: 0.93),
            ]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        let sun = CGPoint(x: w * 0.5, y: h * 0.9)
        let glow = max(w, h) * 0.55
        ctx.fill(Path(ellipseIn: CGRect(x: sun.x - glow, y: sun.y - glow, width: glow * 2, height: glow * 2)),
                 with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.8, blue: 0.5).opacity(0.55), .clear]),
                                       center: sun, startRadius: 0, endRadius: glow))

        for s in stars {
            let fade = max(0, 1 - s.p.y / (h * 0.6))
            let alpha = fade * (0.45 + 0.55 * sin(t * s.twinkle + s.p.x))
            guard alpha > 0.02 else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: s.p.x, y: s.p.y, width: s.size, height: s.size)),
                     with: .color(.white.opacity(alpha)))
        }

        // Two parallax ridges drifting at different speeds.
        drawRidge(in: &ctx, size: size, base: 0.84, amp: 0.05, drift: t * 6, seed: 1.7,
                  color: Color(red: 0.24, green: 0.13, blue: 0.30).opacity(0.85))
        drawRidge(in: &ctx, size: size, base: 0.91, amp: 0.035, drift: t * 14, seed: 4.2,
                  color: Color(red: 0.08, green: 0.05, blue: 0.13))

        // Headline sits in the sky above the button, under the birds.
        let anchor = buttonRect(buttonSize ?? .zero, in: size)
        drawHeadline(in: &ctx, center: CGPoint(x: w / 2, y: anchor.minY - 118), size: size, time: t)
        var subheadline = ctx.resolve(Text("Every agent. Every worktree. One window.")
            .font(.system(size: 22, weight: .medium)))
        subheadline.shading = .color(.white.opacity(0.7))
        ctx.draw(subheadline, at: CGPoint(x: w / 2, y: anchor.minY - 58))

        var wings = Array(repeating: Path(), count: Self.layerScale.count)
        for b in birds {
            let s = 3.2 * Self.layerScale[b.layer]
            let heading = b.v / max(length(b.v), 0.001)
            let side = V(-heading.y, heading.x)
            let flap = V(0, -sin(b.phase) * s * 0.9)
            let back = b.p - heading * s * 0.5
            let left = back + side * s * 1.7 + flap
            let right = back - side * s * 1.7 + flap
            wings[b.layer].move(to: CGPoint(x: left.x, y: left.y))
            wings[b.layer].addLine(to: CGPoint(x: b.p.x, y: b.p.y))
            wings[b.layer].addLine(to: CGPoint(x: right.x, y: right.y))
        }
        for (layer, path) in wings.enumerated() {
            let scale = Self.layerScale[layer]
            ctx.stroke(path, with: .color(Color(red: 0.05, green: 0.03, blue: 0.10).opacity(0.55 + 0.3 * scale / 1.3)),
                       style: StrokeStyle(lineWidth: 1.1 * scale, lineCap: .round, lineJoin: .round))
        }
    }

    /// Headline lit by the dusk: warm light from the sun below, cool sky on
    /// top, a breathing bloom behind it, and a slow glint sweeping across.
    private func drawHeadline(in ctx: inout GraphicsContext, center: CGPoint, size: CGSize, time t: Double) {
        let headline = ctx.resolve(Text("Your new agentic IDE").font(.system(size: 60, weight: .bold)))
        let textSize = headline.measure(in: size)
        let bounds = CGRect(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2,
                            width: textSize.width, height: textSize.height)
        let warm = Color(red: 1.0, green: 0.72, blue: 0.48)

        ctx.drawLayer { bloom in
            bloom.addFilter(.blur(radius: 22))
            bloom.opacity = 0.35 + 0.15 * sin(t * 0.6)
            var glow = headline
            glow.shading = .color(warm)
            bloom.draw(glow, at: center)
        }

        ctx.drawLayer { letters in
            letters.clipToLayer { $0.draw(headline, at: center) }
            letters.fill(Path(bounds), with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.93, green: 0.92, blue: 1.0), location: 0.15),
                    .init(color: Color(red: 1.0, green: 0.88, blue: 0.84), location: 0.55),
                    .init(color: warm, location: 0.95),
                ]),
                startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)))

            // A slanted band of light crosses the letters, then rests off-screen.
            let cycle = 7.0
            let progress = t.truncatingRemainder(dividingBy: cycle) / cycle * 2 - 0.5
            let x = bounds.minX + bounds.width * progress
            letters.blendMode = .plusLighter
            letters.fill(Path(bounds), with: .linearGradient(
                Gradient(colors: [.clear, .white.opacity(0.55), .clear]),
                startPoint: CGPoint(x: x - 60, y: bounds.minY),
                endPoint: CGPoint(x: x + 20, y: bounds.maxY)))
        }
    }

    private func drawRidge(in ctx: inout GraphicsContext, size: CGSize, base: Double, amp: Double,
                           drift: Double, seed: Double, color: Color) {
        let w = size.width, h = size.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        for x in stride(from: 0.0, through: w, by: 6) {
            let u = (x + drift) / w
            let y = h * (base - amp * (sin(u * 7 + seed) * 0.6 + sin(u * 17 + seed * 2) * 0.3 + sin(u * 41) * 0.1))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }

    private func seed(_ size: CGSize) {
        let w = size.width, h = size.height
        let startBirds = self.size == .zero || birds.isEmpty
        self.size = size
        stars = (0..<160).map { _ in
            Star(p: V(.random(in: 0...w), .random(in: 0...(h * 0.6))),
                 size: .random(in: 0.6...1.8), twinkle: .random(in: 0.5...2.5))
        }
        guard startBirds else { return }
        birds = (0..<Self.birdCount).map { _ in
            let angle = Double.random(in: 0..<(2 * .pi))
            return Bird(p: V(w * 0.5 + .random(in: -120...120), h * 0.35 + .random(in: -60...60)),
                        v: V(cos(angle), sin(angle)) * 110,
                        phase: .random(in: 0..<(2 * .pi)),
                        layer: Int.random(in: 0..<Self.layerScale.count))
        }
    }

    private func buttonRect(_ button: CGSize, in size: CGSize) -> CGRect {
        CGRect(x: (size.width - button.width) / 2,
               y: (size.height - button.height) / 2 + Self.buttonOffset,
               width: button.width, height: button.height)
    }

    private func length(_ v: V) -> Double { (v * v).sum().squareRoot() }
}
