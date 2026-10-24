import AlasCore
import AppKit
import QuartzCore
import Synchronization

/// Draws the agent's cursor in a click-through panel ordered just above the
/// target window. It never moves the real cursor, takes focus or activates Alas.
@MainActor
final class ComputerUseCursorOverlay: NSObject {
    private let lookupWindow: @Sendable (UInt32) async -> ComputerUseWindow?

    private var panel: ComputerUseCursorPanel?
    private var canvas: NSView?
    /// Positioned at the pointer tip; holds the body and its beam.
    private var pointerLayer: CALayer?
    /// The stroke mask whose moving segment reveals the pointer's beam gradient.
    private var pointerBeamMask: CAShapeLayer?
    private var outlineLayer: CALayer?

    private var target: ComputerUseWindow?
    /// Pointer tip in window-local, top-left points; nil while it has no place in the target.
    private var pointer: CGPoint? {
        didSet {
            if let pointer, let target { lastPointers[Self.key(target)] = pointer }
        }
    }
    /// Where the pointer last was in each window, window-local, across fades and re-presents.
    private var lastPointers: [ComputerUseCursorWindowKey: CGPoint] = [:]

    private var followTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    /// Bumped whenever a pending fade-out must not order the panel out.
    private var fadeGeneration = 0

    private var motion: Motion?
    private var motionCounter = 0
    private var displayLink: CADisplayLink?

    private nonisolated let shownWindowIDs = Mutex<Set<UInt32>>([])

    /// The overlay's own window number while it is on screen, otherwise empty.
    nonisolated var windowIDs: Set<UInt32> { shownWindowIDs.withLock { $0 } }

    init(window: @escaping @Sendable (UInt32) async -> ComputerUseWindow?) {
        lookupWindow = window
        super.init()
    }

    // MARK: - Showing

    /// Shows the overlay over `window`, or moves it there, without activating Alas.
    func present(over window: ComputerUseWindow) {
        let panel = panel ?? makePanel()
        let wasShown = panel.isVisible && !shownWindowIDs.withLock { $0.isEmpty }
        let reset = !wasShown || target?.windowID != window.windowID || target?.app.pid != window.app.pid
        if reset {
            finishMotion()
            pointer = nil
            hidePointer()
            removeOutline()
        }
        target = window
        cancelFade()
        reframe(to: window.frame)
        // Back where it last was in this window, so the next glide starts there.
        let key = Self.key(window)
        if reset, lastPointers[key] != nil {
            let start = ComputerUseCursorMotion.startPoint(in: key, size: window.frame.size, last: lastPointers)
            pointer = start
            setPointer(at: start)
            showPointer()
        }
        panel.order(.above, relativeTo: Int(window.windowID))
        shownWindowIDs.withLock { $0 = [UInt32(panel.windowNumber)] }
        startFollowing()
        restartIdleTimer()
    }

    /// Hides at once and stops following the target window.
    func dismiss() {
        followTask?.cancel()
        followTask = nil
        idleTask?.cancel()
        idleTask = nil
        fadeGeneration += 1
        finishMotion()
        removeOutline()
        target = nil
        pointer = nil
        hidePointer()
        if let panel {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
        shownWindowIDs.withLock { $0 = [] }
    }

    // MARK: - Cues

    /// Returns when a glide or jump has finished moving (or the task is cancelled);
    /// the ripple and outline keep animating afterwards.
    func perform(_ cue: ComputerUseCursorCue) async {
        guard target != nil, let panel, panel.isVisible else { return }
        cancelFade()
        restartIdleTimer()
        defer { restartIdleTimer() }

        switch cue {
        case .none:
            return
        case .hide:
            finishMotion()
            hidePointer()
        case .outline(let frame):
            showOutline(cgRect: frame)
        case .glide(let point, let outline, let click):
            guard let to = localPoint(fromCG: point) else { return }
            if let outline { showOutline(cgRect: outline) }
            let from = pointer ?? startPoint
            let duration = ComputerUseCursorMotion.glideDuration(from: from, to: to)
            if await move(.glide, from: from, to: to, duration: duration), click {
                ripple(at: to)
            }
        case .jump(let point, let outline, let click):
            guard let to = localPoint(fromCG: point) else { return }
            if let outline { showOutline(cgRect: outline) }
            let from = pointer ?? startPoint
            if await move(.jump, from: from, to: to, duration: ComputerUseCursorMotion.jumpDuration), click {
                ripple(at: to)
            }
        }
    }

    // MARK: - Panel

    private func makePanel() -> ComputerUseCursorPanel {
        let panel = ComputerUseCursorPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.sharingType = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        // NSPanel hides on deactivation by default, and Alas is usually inactive here.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        // Unflipped, so the backing layer's origin is bottom-left; `layerPoint` flips.
        let canvas = NSView(frame: .zero)
        canvas.wantsLayer = true
        canvas.autoresizingMask = [.width, .height]
        panel.contentView = canvas

        let scale = panel.backingScaleFactor
        let path = Self.pointerPath()
        let pointerLayer = CALayer()
        pointerLayer.zPosition = 2
        pointerLayer.isHidden = true
        pointerLayer.actions = Self.noActions

        let body = CAShapeLayer()
        body.path = path
        body.fillColor = Self.pointerFill.cgColor
        body.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        body.lineWidth = 2
        body.lineJoin = .round
        body.shadowColor = NSColor.black.cgColor
        body.shadowOpacity = 0.3
        body.shadowRadius = 2
        body.shadowOffset = CGSize(width: 0, height: -1)
        body.shadowPath = path
        body.actions = Self.noActions
        pointerLayer.addSublayer(body)

        let (beam, mask) = Self.beamLayer(along: path)
        pointerLayer.addSublayer(beam)
        Self.setContentsScale(scale, of: pointerLayer)
        canvas.layer?.addSublayer(pointerLayer)
        pointerBeamMask = mask

        self.panel = panel
        self.canvas = canvas
        self.pointerLayer = pointerLayer
        return panel
    }

    private func reframe(to cgFrame: CGRect) {
        guard let panel else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? cgFrame.maxY
        let frame = ComputerUseCursorMotion.appKitFrame(fromCG: cgFrame, primaryScreenHeight: primaryHeight)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        // Added layers keep a 1x scale unless told; a move to another display may change it.
        let scale = panel.backingScaleFactor
        for layer in [pointerLayer, outlineLayer].compactMap({ $0 }) { Self.setContentsScale(scale, of: layer) }
        target?.frame = cgFrame
        // The pointer is window-local, so it rides along with the window.
        if let pointer { setPointer(at: pointer) }
    }

    // MARK: - Following

    private func startFollowing() {
        guard followTask == nil else { return }
        followTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                await self.followTick()
            }
        }
    }

    private func followTick() async {
        guard let watched = target else { return }
        let current = await lookupWindow(watched.windowID)
        // The target may have changed or been dismissed while the lookup ran.
        guard let target, target.windowID == watched.windowID, target.app.pid == watched.app.pid else { return }
        guard let current, current.app.pid == target.app.pid else {
            dismiss()
            return
        }
        if current.frame != target.frame { reframe(to: current.frame) }
        if let panel, panel.isVisible { panel.order(.above, relativeTo: Int(target.windowID)) }
    }

    // MARK: - Idle fade

    private func restartIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ComputerUseCursorMotion.idleFadeDelay)
            guard !Task.isCancelled, let self else { return }
            self.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel, panel.isVisible, motion == nil else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ComputerUseCursorMotion.fadeDuration.seconds
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation, let panel = self.panel else { return }
                self.followTask?.cancel()
                self.followTask = nil
                self.finishMotion()
                self.removeOutline()
                self.stopPointerBeam()
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.shownWindowIDs.withLock { $0 = [] }
            }
        }
    }

    private func cancelFade() {
        fadeGeneration += 1
        // Always reset: an in-flight window alpha animation may not have moved the model value yet.
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.alphaValue = 1
    }

    // MARK: - Motion

    private enum MotionKind { case glide, jump }

    private struct Motion {
        var id: Int
        var kind: MotionKind
        var from: CGPoint
        var to: CGPoint
        var start: CFTimeInterval
        var duration: CFTimeInterval
        var continuation: CheckedContinuation<Bool, Never>
        var safety: Task<Void, Never>
    }

    private static func key(_ window: ComputerUseWindow) -> ComputerUseCursorWindowKey {
        ComputerUseCursorWindowKey(pid: window.app.pid, windowID: window.windowID)
    }

    /// Where a motion starts when the pointer has no place in the target yet.
    private var startPoint: CGPoint {
        guard let target else { return .zero }
        return ComputerUseCursorMotion.startPoint(in: Self.key(target), size: target.frame.size, last: lastPointers)
    }

    /// Animates the pointer to `to`; true when it arrived, false when cancelled or superseded.
    private func move(_ kind: MotionKind, from: CGPoint, to: CGPoint, duration: Duration) async -> Bool {
        finishMotion()
        motionCounter += 1
        let id = motionCounter
        pointer = from
        setPointer(at: from)
        showPointer()
        guard !Task.isCancelled else { return false }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let seconds = duration.seconds
                // If the display link never fires (window off every screen), still finish.
                let safety = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: duration + .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    self?.completeMotion(id: id)
                }
                motion = Motion(
                    id: id, kind: kind, from: from, to: to,
                    start: CACurrentMediaTime(), duration: seconds,
                    continuation: continuation, safety: safety
                )
                if let canvas {
                    let link = canvas.displayLink(target: self, selector: #selector(step(_:)))
                    link.add(to: .main, forMode: .common)
                    displayLink = link
                }
                if Task.isCancelled { finishMotion() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishMotion(id: id) }
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let motion else {
            link.invalidate()
            return
        }
        let progress = motion.duration > 0 ? (CACurrentMediaTime() - motion.start) / motion.duration : 1
        if progress >= 1 {
            completeMotion(id: motion.id)
            return
        }
        switch motion.kind {
        case .glide:
            let point = ComputerUseCursorMotion.position(from: motion.from, to: motion.to, progress: progress)
            pointer = point
            setPointer(at: point)
        case .jump:
            // Fade out where it is, reappear at the destination.
            let atTarget = progress >= 0.5
            let point = atTarget ? motion.to : motion.from
            pointer = point
            setPointer(at: point)
            withoutActions { pointerLayer?.opacity = Float(atTarget ? progress * 2 - 1 : 1 - progress * 2) }
        }
    }

    /// The motion reached its destination.
    private func completeMotion(id: Int) {
        guard let motion, motion.id == id else { return }
        pointer = motion.to
        setPointer(at: motion.to)
        withoutActions { pointerLayer?.opacity = 1 }
        endMotion(arrived: true)
    }

    /// Stops the motion with `id` (or any motion) where it is.
    private func finishMotion(id: Int? = nil) {
        guard let motion, id == nil || motion.id == id else { return }
        withoutActions { pointerLayer?.opacity = 1 }
        endMotion(arrived: false)
    }

    private func endMotion(arrived: Bool) {
        guard let current = motion else { return }
        motion = nil
        displayLink?.invalidate()
        displayLink = nil
        current.safety.cancel()
        current.continuation.resume(returning: arrived)
    }

    // MARK: - Drawing

    private func setPointer(at local: CGPoint) {
        withoutActions { pointerLayer?.position = layerPoint(local) }
    }

    private func showPointer() {
        withoutActions {
            pointerLayer?.opacity = 1
            pointerLayer?.isHidden = false
        }
        startPointerBeam()
    }

    private func hidePointer() {
        withoutActions { pointerLayer?.isHidden = true }
        stopPointerBeam()
    }

    /// Runs the pointer's beam while the pointer is shown; idempotent.
    private func startPointerBeam() {
        guard let pointerBeamMask, pointerBeamMask.animation(forKey: Self.beamKey) == nil else { return }
        Self.runBeam(on: pointerBeamMask, fraction: Self.pointerBeamFraction, lap: Self.pointerBeamLap)
    }

    /// Nothing keeps animating once the pointer is hidden or the panel is ordered out.
    private func stopPointerBeam() {
        pointerBeamMask?.removeAnimation(forKey: Self.beamKey)
    }

    private func ripple(at local: CGPoint) {
        guard let root = canvas?.layer else { return }
        let radius: CGFloat = 14
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.fillColor = Self.beamColors[0].withAlphaComponent(0.15).cgColor
        ring.strokeColor = Self.beamColors[0].cgColor
        ring.lineWidth = 2
        ring.contentsScale = panel?.backingScaleFactor ?? 2
        ring.zPosition = 1
        ring.actions = Self.noActions
        ring.position = layerPoint(local)
        ring.opacity = 0

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = ComputerUseCursorMotion.rippleDuration.seconds
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        root.addSublayer(ring)
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    private func showOutline(cgRect: CGRect) {
        removeOutline()
        guard let root = canvas?.layer, let target else { return }
        let local = CGRect(
            x: cgRect.minX - target.frame.minX,
            y: cgRect.minY - target.frame.minY,
            width: cgRect.width, height: cgRect.height
        ).insetBy(dx: -3, dy: -3)
        let bottomLeft = CGRect(x: local.minX, y: target.frame.height - local.maxY, width: local.width, height: local.height)

        let path = CGPath(roundedRect: bottomLeft, cornerWidth: 4, cornerHeight: 4, transform: nil)
        let outline = CALayer()
        outline.actions = Self.noActions
        outline.opacity = 0

        let ring = CAShapeLayer()
        ring.path = path
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Self.beamColors[0].withAlphaComponent(0.25).cgColor
        ring.lineWidth = 2
        ring.actions = Self.noActions
        outline.addSublayer(ring)

        let (beam, mask) = Self.beamLayer(along: path)
        outline.addSublayer(beam)
        Self.runBeam(on: mask, fraction: Self.outlineBeamFraction, lap: Self.outlineBeamLap)
        Self.setContentsScale(panel?.backingScaleFactor ?? 2, of: outline)

        // Fully visible for `outlineDuration`, then fade out.
        let hold = ComputerUseCursorMotion.outlineDuration.seconds
        let fadeTime = ComputerUseCursorMotion.fadeDuration.seconds
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: hold / (hold + fadeTime)), 1]
        fade.duration = hold + fadeTime

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak outline] in
            MainActor.assumeIsolated {
                guard let outline else { return }
                outline.removeFromSuperlayer()
                if self?.outlineLayer === outline { self?.outlineLayer = nil }
            }
        }
        root.addSublayer(outline)
        outline.add(fade, forKey: "outline")
        CATransaction.commit()
        outlineLayer = outline
    }

    private func removeOutline() {
        outlineLayer?.removeFromSuperlayer()
        outlineLayer = nil
    }

    // MARK: - Geometry

    /// CG global, top-left point to window-local, top-left; nil without a target.
    /// Nil outside the target, so the pointer never moves (nor is remembered) off the panel.
    private func localPoint(fromCG point: CGPoint) -> CGPoint? {
        guard let target else { return nil }
        let local = CGPoint(x: point.x - target.frame.minX, y: point.y - target.frame.minY)
        guard (0 ... target.frame.width).contains(local.x), (0 ... target.frame.height).contains(local.y) else { return nil }
        return local
    }

    /// Window-local, top-left point to the canvas layer's bottom-left space.
    private func layerPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x, y: (target?.frame.height ?? 0) - local.y)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "opacity": NSNull(), "hidden": NSNull(), "path": NSNull(),
        "strokeStart": NSNull(), "strokeEnd": NSNull(),
    ]

    // MARK: - Beam

    private static let beamKey = "beam"
    private static let beamWidth: CGFloat = 2.6
    private static let pointerBeamFraction: CGFloat = 0.2
    private static let pointerBeamLap: CFTimeInterval = 1.6
    private static let outlineBeamFraction: CGFloat = 0.17
    private static let outlineBeamLap: CFTimeInterval = 2.2

    private static let pointerFill = NSColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x1A / 255, alpha: 1)
    /// The AI gradient, #7B5CFF → #3AB8FF → #FF5CC8 → #FFB347.
    private static let beamColors: [NSColor] = [
        NSColor(srgbRed: 0x7B / 255, green: 0x5C / 255, blue: 0xFF / 255, alpha: 1),
        NSColor(srgbRed: 0x3A / 255, green: 0xB8 / 255, blue: 0xFF / 255, alpha: 1),
        NSColor(srgbRed: 0xFF / 255, green: 0x5C / 255, blue: 0xC8 / 255, alpha: 1),
        NSColor(srgbRed: 0xFF / 255, green: 0xB3 / 255, blue: 0x47 / 255, alpha: 1),
    ]

    /// A gradient covering `path`, masked by a stroke of it; returns the gradient and its mask.
    /// The mask strokes the path twice in a row, so a segment can wrap past the start point.
    private static func beamLayer(along path: CGPath) -> (CAGradientLayer, CAShapeLayer) {
        let frame = path.boundingBoxOfPath.insetBy(dx: -beamWidth, dy: -beamWidth)
        let gradient = CAGradientLayer()
        gradient.frame = frame
        gradient.colors = beamColors.map(\.cgColor)
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.actions = noActions

        let offset = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        let twice = CGMutablePath()
        twice.addPath(path, transform: offset)
        twice.addPath(path, transform: offset)
        let mask = CAShapeLayer()
        mask.frame = gradient.bounds
        mask.path = twice
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = beamWidth
        mask.lineCap = .round
        mask.lineJoin = .round
        mask.actions = noActions
        gradient.mask = mask
        return (gradient, mask)
    }

    /// Sends a segment `fraction` of one lap long around the doubled path, one lap per `lap`
    /// seconds. With Reduce Motion the whole outline stays lit instead.
    private static func runBeam(on mask: CAShapeLayer, fraction: CGFloat, lap: CFTimeInterval) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            mask.strokeStart = 0
            mask.strokeEnd = 0.5
            return
        }
        mask.strokeStart = 0
        mask.strokeEnd = fraction / 2
        let head = CABasicAnimation(keyPath: "strokeEnd")
        head.fromValue = fraction / 2
        head.toValue = 0.5 + fraction / 2
        let tail = CABasicAnimation(keyPath: "strokeStart")
        tail.fromValue = 0
        tail.toValue = 0.5
        let group = CAAnimationGroup()
        group.animations = [head, tail]
        group.duration = lap
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        mask.add(group, forKey: beamKey)
    }

    private static func setContentsScale(_ scale: CGFloat, of layer: CALayer) {
        if layer.contentsScale != scale { layer.contentsScale = scale }
        if let mask = layer.mask { setContentsScale(scale, of: mask) }
        for sublayer in layer.sublayers ?? [] { setContentsScale(scale, of: sublayer) }
    }

    /// A rounded arrowhead with no tail, about 22 pt tall, tip at the origin, in a bottom-left space.
    private static func pointerPath() -> CGPath {
        // The approved mockup's path in a 44 x 44 top-left box; its tip, the outline's
        // extreme toward the top-left, sits at about (6.3, 2.3).
        let tip = CGPoint(x: 6.3, y: 2.3)
        let scale: CGFloat = 22.0 / 36
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: (x - tip.x) * scale, y: -(y - tip.y) * scale)
        }
        let path = CGMutablePath()
        path.move(to: p(6, 4.5))
        path.addCurve(to: p(8.7, 2), control1: p(5.2, 2.6), control2: p(6.9, 1.2))
        path.addLine(to: p(36, 14.6))
        path.addCurve(to: p(35.7, 19.1), control1: p(38.1, 15.6), control2: p(37.9, 18.5))
        path.addLine(to: p(23.6, 22.4))
        path.addCurve(to: p(21.7, 24.2), control1: p(22.7, 22.6), control2: p(22, 23.3))
        path.addLine(to: p(18.2, 36))
        path.addCurve(to: p(13.8, 36.2), control1: p(17.6, 38.2), control2: p(14.6, 38.3))
        path.closeSubpath()
        return path
    }
}

/// Never key or main, so the overlay can't take focus from the user or the target.
private final class ComputerUseCursorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
