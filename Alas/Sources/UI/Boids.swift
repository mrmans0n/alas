import SwiftUI

/// Classic boids flock shared by the animated scenes (welcome sky, forest).
/// Birds align with, gather toward, and keep clear of their neighbors while
/// chasing a goal and fleeing a point such as the cursor.
struct Boids {
    typealias V = SIMD2<Double>

    struct Bird {
        var p: V
        var v: V
        var phase: Double
        var layer: Int
    }

    static let layerScale: [Double] = [0.75, 1.0, 1.3]

    var birds: [Bird] = []

    mutating func seed(count: Int, around center: V, spread: V) {
        birds = (0..<count).map { _ in
            let angle = Double.random(in: 0..<(2 * .pi))
            return Bird(p: center + V(.random(in: -spread.x...spread.x), .random(in: -spread.y...spread.y)),
                        v: V(cos(angle), sin(angle)) * 110,
                        phase: .random(in: 0..<(2 * .pi)),
                        layer: Int.random(in: 0..<Self.layerScale.count))
        }
    }

    mutating func step(dt: Double, goal: V, goalPull: Double = 55, flee: V?,
                       speed: ClosedRange<Double> = 70...170) {
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
            a += toGoal / max(Self.length(toGoal), 1) * goalPull
            if let flee {
                let away = b.p - flee
                let dist = Self.length(away)
                if dist < 160 { a += away / max(dist, 1) * 1400 * (1 - dist / 160) }
            }

            var v = b.v + a * dt
            let s = Self.length(v)
            v = v / max(s, 0.001) * min(max(s, speed.lowerBound), speed.upperBound)
            next[i].v = v
            next[i].p = b.p + v * dt
            next[i].phase += dt * (9 + s / 25)
        }
        birds = next
    }

    /// Flapping chevrons, one path per depth layer so nearer birds can be
    /// stroked thicker.
    func wings(size: Double = 3.2) -> [Path] {
        var wings = Array(repeating: Path(), count: Self.layerScale.count)
        for b in birds {
            let s = size * Self.layerScale[b.layer]
            let heading = b.v / max(Self.length(b.v), 0.001)
            let side = V(-heading.y, heading.x)
            let flap = V(0, -sin(b.phase) * s * 0.9)
            let back = b.p - heading * s * 0.5
            let left = back + side * s * 1.7 + flap
            let right = back - side * s * 1.7 + flap
            wings[b.layer].move(to: CGPoint(x: left.x, y: left.y))
            wings[b.layer].addLine(to: CGPoint(x: b.p.x, y: b.p.y))
            wings[b.layer].addLine(to: CGPoint(x: right.x, y: right.y))
        }
        return wings
    }

    func drawWings(in ctx: inout GraphicsContext, color: Color, size: Double = 3.2) {
        for (layer, path) in wings(size: size).enumerated() {
            let scale = Self.layerScale[layer]
            ctx.stroke(path, with: .color(color.opacity(0.55 + 0.3 * scale / 1.3)),
                       style: StrokeStyle(lineWidth: 1.1 * scale, lineCap: .round, lineJoin: .round))
        }
    }

    /// Rolling horizon filled to the bottom edge, scrolled sideways by `drift`.
    static func ridge(size: CGSize, base: Double, amp: Double, drift: Double, seed: Double) -> Path {
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
        return path
    }

    static func length(_ v: V) -> Double { (v * v).sum().squareRoot() }
}
