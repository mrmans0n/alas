import AlasCore
import AppKit
import QuartzCore
import Synchronization

/// Draws the agent's cursor in a click-through panel ordered just above the
/// target window. It never moves the real cursor, takes focus or activates Alas.
@MainActor
final class ComputerUseCursorOverlay: NSObject {
    private let lookupWindow: @Sendable (UInt32) async -> ComputerUseWindow?
    private let accentColor: NSColor

    private var panel: ComputerUseCursorPanel?
    private var canvas: NSView?
    private var pointerLayer: CAShapeLayer?
    private var outlineLayer: CAShapeLayer?

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

    init(
        window: @escaping @Sendable (UInt32) async -> ComputerUseWindow?,
        accentColor: NSColor = .controlAccentColor
    ) {
        lookupWindow = window
        self.accentColor = accentColor
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
            pointerLayer?.isHidden = true
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
            pointerLayer?.opacity = 1
            pointerLayer?.isHidden = false
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
        pointerLayer?.isHidden = true
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
            pointerLayer?.isHidden = true
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

        let pointerLayer = CAShapeLayer()
        pointerLayer.path = Self.pointerPath()
        pointerLayer.fillColor = accentColor.cgColor
        pointerLayer.strokeColor = NSColor.white.cgColor
        pointerLayer.lineWidth = 1.5
        pointerLayer.lineJoin = .round
        pointerLayer.shadowColor = NSColor.black.cgColor
        pointerLayer.shadowOpacity = 0.3
        pointerLayer.shadowRadius = 2
        pointerLayer.shadowOffset = CGSize(width: 0, height: -1)
        pointerLayer.shadowPath = pointerLayer.path
        pointerLayer.contentsScale = panel.backingScaleFactor
        pointerLayer.zPosition = 2
        pointerLayer.isHidden = true
        pointerLayer.actions = Self.noActions
        canvas.layer?.addSublayer(pointerLayer)

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
        for layer in [pointerLayer, outlineLayer].compactMap({ $0 }) where layer.contentsScale != scale {
            layer.contentsScale = scale
        }
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
        pointerLayer?.opacity = 1
        pointerLayer?.isHidden = false
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

    private func ripple(at local: CGPoint) {
        guard let root = canvas?.layer else { return }
        let radius: CGFloat = 14
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.fillColor = accentColor.withAlphaComponent(0.15).cgColor
        ring.strokeColor = accentColor.cgColor
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

        let outline = CAShapeLayer()
        outline.path = CGPath(roundedRect: bottomLeft, cornerWidth: 4, cornerHeight: 4, transform: nil)
        outline.fillColor = NSColor.clear.cgColor
        outline.strokeColor = accentColor.cgColor
        outline.lineWidth = 2
        outline.contentsScale = panel?.backingScaleFactor ?? 2
        outline.actions = Self.noActions
        outline.opacity = 0

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
    private func localPoint(fromCG point: CGPoint) -> CGPoint? {
        guard let target else { return nil }
        return CGPoint(x: point.x - target.frame.minX, y: point.y - target.frame.minY)
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
    ]

    /// A classic arrow pointer, about 22 pt tall, tip at the origin, in a bottom-left space.
    private static func pointerPath() -> CGPath {
        // Designed top-left with y growing down; flipped to y-up below.
        let points: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 17), CGPoint(x: 4.3, y: 13.2),
            CGPoint(x: 7.2, y: 19.6), CGPoint(x: 10.2, y: 18.3), CGPoint(x: 7.4, y: 12.1),
            CGPoint(x: 13, y: 12.1),
        ]
        let scale: CGFloat = 22.0 / 19.6
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x * scale, y: -$0.y * scale) })
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
