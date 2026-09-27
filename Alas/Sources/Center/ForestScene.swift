import SwiftUI

/// Animated forest behind the worktree empty and loading states: dawn in
/// light themes, a firefly night in dark ones. Swallows wheel above the
/// canopy (or circle like a spinner while loading), scatter from the cursor,
/// and take off out of frame when the scene is removed with `.takeOff`.
enum ForestMode { case idle, loading }

struct ForestScene<Content: View>: View {
    let mode: ForestMode
    @ViewBuilder var content: Content
    @State private var forest = ForestFlock()
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.forestTakingOff) private var takingOff

    var body: some View {
        let palette = theme.darkMode ? ForestPalette.night : .dawn
        ZStack {
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    forest.step(to: t, in: size, mode: mode)
                    forest.draw(in: &ctx, size: size, time: t, palette: palette)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            content
                .foregroundStyle(palette.text)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let point) = phase { forest.cursor = point } else { forest.cursor = nil }
        }
        .onChange(of: takingOff, initial: true) { _, leaving in forest.takingOff = leaving }
    }
}

extension EnvironmentValues {
    /// Set by `.takeOff` while a `ForestScene` is being removed.
    @Entry var forestTakingOff = false
}

/// Removal sends the flock out of frame while the scene fades, blurs, and
/// drifts toward the viewer; insertion is the same fade in reverse.
struct TakeOffTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .environment(\.forestTakingOff, phase == .didDisappear)
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 10)
            .scaleEffect(phase == .didDisappear ? 1.04 : 1)
    }
}

extension Transition where Self == TakeOffTransition {
    static var takeOff: TakeOffTransition { TakeOffTransition() }
}

extension Animation {
    /// Long enough for the flock to clear the frame before the scene is gone.
    static let takeOff = Animation.easeIn(duration: 0.7)
}

struct ForestPalette {
    let sky: [Gradient.Stop]
    let glow: Color
    let glowCenter: UnitPoint
    let trees: [Color]
    let mist: Color
    let bird: Color
    let text: Color
    let night: Bool

    static let dawn = ForestPalette(
        sky: [
            .init(color: Color(red: 0.55, green: 0.73, blue: 0.90), location: 0),
            .init(color: Color(red: 0.80, green: 0.85, blue: 0.90), location: 0.40),
            .init(color: Color(red: 0.99, green: 0.86, blue: 0.72), location: 0.68),
            .init(color: Color(red: 1.00, green: 0.78, blue: 0.60), location: 0.85),
        ],
        glow: Color(red: 1.0, green: 0.93, blue: 0.75),
        glowCenter: UnitPoint(x: 0.72, y: 0.62),
        trees: [
            Color(red: 0.60, green: 0.70, blue: 0.72),
            Color(red: 0.35, green: 0.49, blue: 0.49),
            Color(red: 0.14, green: 0.25, blue: 0.24),
        ],
        mist: .white.opacity(0.45),
        bird: Color(red: 0.12, green: 0.15, blue: 0.20),
        text: Color(red: 0.10, green: 0.14, blue: 0.18),
        night: false
    )

    static let night = ForestPalette(
        sky: [
            .init(color: Color(red: 0.01, green: 0.02, blue: 0.06), location: 0),
            .init(color: Color(red: 0.03, green: 0.07, blue: 0.13), location: 0.45),
            .init(color: Color(red: 0.07, green: 0.15, blue: 0.19), location: 0.80),
        ],
        glow: Color(red: 0.70, green: 0.82, blue: 1.0),
        glowCenter: UnitPoint(x: 0.76, y: 0.20),
        trees: [
            Color(red: 0.06, green: 0.12, blue: 0.15),
            Color(red: 0.04, green: 0.08, blue: 0.10),
            Color(red: 0.01, green: 0.03, blue: 0.04),
        ],
        mist: Color(red: 0.55, green: 0.70, blue: 0.85).opacity(0.10),
        bird: Color(red: 0.62, green: 0.72, blue: 0.82),
        text: .white,
        night: true
    )
}

final class ForestFlock {
    private typealias V = Boids.V

    var cursor: CGPoint?
    var takingOff = false

    private var flock = Boids()
    private var lastTime: Double?
    private var takeOffTarget: V?

    private static let birdCount = 90
    private static let moteCount = 70
    private static let fireflyCount = 34

    func step(to t: Double, in size: CGSize, mode: ForestMode) {
        guard size.width > 0, size.height > 0 else { return }
        let w = size.width, h = size.height
        if flock.birds.isEmpty {
            let center = mode == .loading ? V(w * 0.5, h * 0.4) : V(w * 0.3, h * 0.3)
            flock.seed(count: Self.birdCount, around: center, spread: V(90, 50))
        }
        let dt = min(max(t - (lastTime ?? t), 0), 1.0 / 30)
        lastTime = t
        guard dt > 0 else { return }

        if takingOff {
            // Burst up and away toward whichever top corner is nearer.
            if takeOffTarget == nil {
                let leftSide = (flock.birds.first?.p.x ?? w) < w / 2
                takeOffTarget = V(leftSide ? -w * 0.2 : w * 1.2, -h * 0.6)
            }
            let target = takeOffTarget ?? .zero
            flock.step(dt: dt, goal: target, goalPull: 900, flee: nil, speed: 160...620)
            return
        }
        takeOffTarget = nil
        switch mode {
        case .idle:
            // Wheel above the canopy, sweeping across the sky.
            let goal = V(w * (0.5 + 0.36 * sin(t * 0.11) * cos(t * 0.047)),
                         h * (0.30 + 0.10 * sin(t * 0.17 + 1.3)))
            flock.step(dt: dt, goal: goal, flee: cursor.map { V($0.x, $0.y) }, speed: 60...150)
        case .loading:
            // A goal racing around a ring pulls the flock into a living spinner.
            let goal = V(w * 0.5 + 80 * cos(t * 1.7), h * 0.4 + 50 * sin(t * 1.7))
            flock.step(dt: dt, goal: goal, goalPull: 220, flee: cursor.map { V($0.x, $0.y) }, speed: 90...200)
        }
    }

    func draw(in ctx: inout GraphicsContext, size: CGSize, time t: Double, palette: ForestPalette) {
        let w = size.width, h = size.height

        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
            Gradient(stops: palette.sky), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        let glowCenter = CGPoint(x: w * palette.glowCenter.x, y: h * palette.glowCenter.y)
        let glow = max(w, h) * 0.5
        ctx.fill(Path(ellipseIn: CGRect(x: glowCenter.x - glow, y: glowCenter.y - glow, width: glow * 2, height: glow * 2)),
                 with: .radialGradient(Gradient(colors: [palette.glow.opacity(0.6), .clear]),
                                       center: glowCenter, startRadius: 0, endRadius: glow))
        if palette.night {
            ctx.fill(Path(ellipseIn: CGRect(x: glowCenter.x - 16, y: glowCenter.y - 16, width: 32, height: 32)),
                     with: .color(Color(red: 0.93, green: 0.95, blue: 1.0).opacity(0.9)))
            drawStars(in: &ctx, size: size, time: t)
        }

        flock.drawWings(in: &ctx, color: palette.bird, size: 2.8)

        // Far to near pine layers, each with mist settling in front of it.
        let layers: [(base: Double, spacing: Double, height: ClosedRange<Double>, speed: Double)] = [
            (0.70, 22, 40...80, 3), (0.82, 34, 70...130, 7), (0.95, 56, 120...210, 13),
        ]
        let scale = max(h / 700, 0.6)
        for (i, layer) in layers.enumerated() {
            let pines = Self.pines(size: size, base: layer.base, spacing: layer.spacing * scale,
                                   height: (layer.height.lowerBound * scale)...(layer.height.upperBound * scale),
                                   drift: t * layer.speed, seed: Double(i) * 3.1 + 0.7)
            ctx.fill(pines, with: .color(palette.trees[i]))
            let bandY = h * layer.base - 10 + 6 * sin(t * 0.3 + Double(i))
            ctx.fill(Path(CGRect(x: 0, y: bandY - 40, width: w, height: 80)), with: .linearGradient(
                Gradient(colors: [.clear, palette.mist, .clear]),
                startPoint: CGPoint(x: 0, y: bandY - 40), endPoint: CGPoint(x: 0, y: bandY + 40)))
        }

        if palette.night { drawFireflies(in: &ctx, size: size, time: t) } else { drawPollen(in: &ctx, size: size, time: t) }
    }

    /// Rolling ground topped with three-tier pines, in world coordinates so
    /// the trees stay planted while the layer drifts.
    private static func pines(size: CGSize, base: Double, spacing: Double, height: ClosedRange<Double>,
                              drift: Double, seed: Double) -> Path {
        let w = size.width, h = size.height
        func ground(_ worldX: Double) -> Double {
            h * base - h * 0.03 * (sin(worldX / 180 + seed) * 0.6 + sin(worldX / 70 + seed * 2) * 0.4)
        }
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        for x in stride(from: 0.0, through: w + 6, by: 6) { path.addLine(to: CGPoint(x: x, y: ground(x + drift))) }
        path.addLine(to: CGPoint(x: w + 6, y: h))
        path.closeSubpath()

        let first = Int((drift / spacing).rounded(.down)) - 1
        let last = Int(((drift + w) / spacing).rounded(.up)) + 1
        for k in first...last {
            let r = hash(Double(k), seed)
            let worldX = Double(k) * spacing + (r - 0.5) * spacing * 0.6
            let x = worldX - drift
            let treeH = height.lowerBound + (height.upperBound - height.lowerBound) * hash(Double(k) + 0.5, seed)
            let treeW = treeH * 0.36
            let foot = ground(worldX) + 4
            for tier in 0..<3 {
                let tierBottom = foot - treeH * 0.26 * Double(tier)
                let halfW = treeW * (1 - 0.24 * Double(tier)) / 2
                path.move(to: CGPoint(x: x - halfW, y: tierBottom))
                path.addLine(to: CGPoint(x: x, y: tierBottom - treeH * 0.48))
                path.addLine(to: CGPoint(x: x + halfW, y: tierBottom))
                path.closeSubpath()
            }
        }
        return path
    }

    private func drawStars(in ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        for i in 0..<120 {
            let x = Self.hash(Double(i), 1) * size.width
            let y = Self.hash(Double(i), 2) * size.height * 0.6
            let alpha = (1 - y / (size.height * 0.6)) * (0.4 + 0.5 * sin(t * (0.5 + Self.hash(Double(i), 3) * 2) + x))
            guard alpha > 0.02 else { continue }
            let s = 0.6 + Self.hash(Double(i), 4) * 1.2
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(alpha)))
        }
    }

    /// Stateless drifting motes: position is a function of time, so nothing to step.
    private func drawPollen(in ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = size.width, h = size.height
        for i in 0..<Self.moteCount {
            let d = Double(i)
            let vx = 6 + Self.hash(d, 5) * 14, vy = 4 + Self.hash(d, 6) * 10
            let x = (Self.hash(d, 7) * w + t * vx + sin(t * 0.7 + d) * 10).truncatingRemainder(dividingBy: w)
            var y = (Self.hash(d, 8) * h - t * vy).truncatingRemainder(dividingBy: h)
            if y < 0 { y += h }
            let s = 1.2 + Self.hash(d, 9) * 1.8
            let alpha = 0.35 + 0.35 * sin(t * 1.3 + d)
            ctx.fill(Path(ellipseIn: CGRect(x: x - s, y: y - s, width: s * 2, height: s * 2)),
                     with: .color(Color(red: 1, green: 0.97, blue: 0.85).opacity(alpha)))
        }
    }

    private func drawFireflies(in ctx: inout GraphicsContext, size: CGSize, time t: Double) {
        let w = size.width, h = size.height
        let light = Color(red: 0.85, green: 1.0, blue: 0.45)
        for i in 0..<Self.fireflyCount {
            let d = Double(i)
            let x = Self.hash(d, 10) * w + sin(t * (0.3 + Self.hash(d, 11) * 0.4) + d) * 40
            let y = h * (0.55 + Self.hash(d, 12) * 0.4) + cos(t * (0.25 + Self.hash(d, 13) * 0.3) + d) * 22
            let blink = pow(max(0, sin(t * (0.6 + Self.hash(d, 14) * 0.8) + d * 2.3)), 3)
            guard blink > 0.02 else { continue }
            let r = 14.0
            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [light.opacity(0.45 * blink), .clear]),
                                           center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)),
                     with: .color(light.opacity(blink)))
        }
    }

    /// Deterministic pseudo-random in 0..<1, so trees and particles stay put between frames.
    private static func hash(_ x: Double, _ seed: Double) -> Double {
        let v = sin(x * 12.9898 + seed * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }
}

/// Settings > Advanced > Previews: steps through loading, empty, and an open
/// tab so the take-off transitions can be seen without creating worktrees.
struct ForestScenesPreview: View {
    let onExit: () -> Void
    @State private var stage = 0
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                switch stage {
                case 0:
                    ForestLoadingView(message: "Loading repository…")
                        .transition(.takeOff)
                case 1:
                    EmptyTabView(onNewTerminal: { stage = 2 }, onNewAgentInChat: { stage = 2 },
                                 onNewAgentInTerminal: { stage = 2 }, newTerminalShortcut: nil,
                                 newAgentInChatShortcut: nil, newAgentInTerminalShortcut: nil)
                        .transition(.takeOff)
                default:
                    theme.color("bg-1")
                }
            }
            .animation(.takeOff, value: stage)
            HStack(spacing: 8) {
                AlasButton(title: ["Finish loading", "Open a tab", "Restart"][stage], icon: "forward", style: .normal) {
                    stage = (stage + 1) % 3
                }
                AlasButton(title: "Exit preview", icon: "xmark", style: .normal, action: onExit)
            }
            .padding(12)
        }
    }
}
