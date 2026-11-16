import AVFoundation
import AlasCore
import AppKit
import CoreMedia
import IOSurface
import SwiftUI

/// A simulator's live screen. It watches the device while it is on screen,
/// and turns clicks into touches and keys into HID usages.
struct DeviceScreenView: NSViewRepresentable {
    let udid: String
    let client: any DeviceScreenSource
    var onStopped: (String) -> Void
    /// False while an agent drives: clicks and keys stay off the simulator.
    var allowsInput = true
    var onBlockedClick: () -> Void = {}
    /// A dropped `.app` the simulator can run.
    var onDropApp: (URL) -> Void = { _ in }
    /// Whether such a drag is over the screen.
    var onDropTargeted: (Bool) -> Void = { _ in }
    /// Whether a dropped file is one this device can run.
    var canDrop: (URL) -> Bool = { (try? SimulatorAppBundle.read($0)) != nil }
    /// Edit › Paste (⌘V) while the screen has focus.
    var onPaste: () -> Void = {}
    /// Edit › Copy (⌘C) while the screen has focus.
    var onCopy: () -> Void = {}
    /// The interface orientation of the frames changed.
    var onOrientation: (DeviceScreenOrientation) -> Void = { _ in }
    /// The pointer over the screen, in top-left-origin view points; nil when it leaves.
    var onHover: ((CGPoint?) -> Void)?
    /// The user finished a click, drag or key press on the simulator.
    var onUserInput: () -> Void = {}
    /// A finished click or drag, from and to upright 0…1 points, for recording a flow.
    var onGesture: ((DeviceScreenPoint, DeviceScreenPoint) -> Void)?
    /// The characters of a key press sent to the device, for recording a flow.
    var onText: ((String) -> Void)?
    /// A scroll's deltas as sent to the device, for recording a flow.
    var onScroll: ((Double, Double) -> Void)?

    func makeNSView(context: Context) -> DeviceScreenNSView {
        let view = DeviceScreenNSView()
        view.onStopped = onStopped
        view.onBlockedClick = onBlockedClick
        view.onDropApp = onDropApp
        view.onDropTargeted = onDropTargeted
        view.canDrop = canDrop
        view.onPaste = onPaste
        view.onCopy = onCopy
        view.onOrientation = onOrientation
        view.onHover = onHover
        view.onUserInput = onUserInput
        view.onGesture = onGesture
        view.onText = onText
        view.onScroll = onScroll
        view.allowsInput = allowsInput
        view.attach(udid: udid, client: client)
        return view
    }

    func updateNSView(_ view: DeviceScreenNSView, context: Context) {
        view.onStopped = onStopped
        view.onBlockedClick = onBlockedClick
        view.onDropApp = onDropApp
        view.onDropTargeted = onDropTargeted
        view.canDrop = canDrop
        view.onPaste = onPaste
        view.onCopy = onCopy
        view.onOrientation = onOrientation
        view.onHover = onHover
        view.onUserInput = onUserInput
        view.onGesture = onGesture
        view.onText = onText
        view.onScroll = onScroll
        view.allowsInput = allowsInput
        if view.udid != udid { view.attach(udid: udid, client: client) }
    }

    static func dismantleNSView(_ view: DeviceScreenNSView, coordinator: ()) {
        view.detach()
    }
}

final class DeviceScreenNSView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var udid: String?
    private weak var client: (any DeviceScreenSource)?
    private var token: UUID?
    /// The portrait panel's size in pixels.
    private var screenSize = CGSize.zero
    /// Which way the frames' interface is turned.
    private var orientation = DeviceScreenOrientation.portrait
    private var lastTouch: DeviceScreenPoint?
    private var heldKeys = HeldSimulatorKeys()
    var onStopped: (String) -> Void = { _ in }
    var onBlockedClick: () -> Void = {}
    var onDropApp: (URL) -> Void = { _ in }
    var onDropTargeted: (Bool) -> Void = { _ in }
    var canDrop: (URL) -> Bool = { _ in false }
    var onPaste: () -> Void = {}
    var onCopy: () -> Void = {}
    var onOrientation: (DeviceScreenOrientation) -> Void = { _ in }
    var onHover: ((CGPoint?) -> Void)?
    var onUserInput: () -> Void = {}
    var onGesture: ((DeviceScreenPoint, DeviceScreenPoint) -> Void)?
    var onText: ((String) -> Void)?
    var onScroll: ((Double, Double) -> Void)?
    /// Where the current click started, upright.
    private var gestureStart: DeviceScreenPoint?
    /// Turning input off lifts anything still held, so the agent starts from a clean state.
    var allowsInput = true {
        didSet { if oldValue, !allowsInput { releaseHeldInput() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc func paste(_ sender: Any?) { onPaste() }
    @objc func copy(_ sender: Any?) { onCopy() }

    /// One file this device can run; anything else isn't offered a drop.
    private func droppedApp(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, urls.count == 1, canDrop(urls[0]) else { return nil }
        return urls[0]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedApp(sender) != nil else { return [] }
        guard allowsInput else {
            onBlockedClick()
            return []
        }
        onDropTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDropTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDropTargeted(false)
        guard allowsInput, let app = droppedApp(sender) else { return false }
        onDropApp(app)
        return true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The frames keep the portrait panel's layout; the layer turns them upright.
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(origin: .zero, size: orientation.isLandscape
            ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Angles turn counterclockwise in the layer's unflipped space.
        displayLayer.setAffineTransform(CGAffineTransform(
            rotationAngle: -CGFloat(orientation.clockwiseQuarterTurns) * .pi / 2
        ))
        CATransaction.commit()
    }

    func attach(udid: String, client: any DeviceScreenSource) {
        detach()
        self.udid = udid
#if DEBUG
        // A scripted simulator of a design capture shows a painted screen and never subscribes.
        if DesignCaptureDevices.isDemoUDID(udid) {
            layer?.contents = DesignCaptureDevices.demoScreen
            layer?.contentsGravity = .resizeAspectFill
            return
        }
#endif
        self.client = client
        token = client.subscribe(
            udid: udid,
            onFrame: { [weak self] in self?.show($0) },
            onStop: { [weak self] in self?.onStopped($0) }
        )
    }

    func detach() {
        releaseHeldInput()
        if let udid, let token { client?.unsubscribe(udid: udid, token: token) }
        udid = nil
        token = nil
        screenSize = .zero
        orientation = .portrait
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    // MARK: Frames

    private func show(_ frame: DeviceFrame) {
        let surface = frame.surface
        screenSize = CGSize(width: surface.width, height: surface.height)
        if frame.orientation != orientation {
            orientation = frame.orientation
            needsLayout = true
            onOrientation(orientation)
        }
        var unmanaged: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(nil, surface as IOSurfaceRef, nil, &unmanaged) == kCVReturnSuccess,
              let pixelBuffer = unmanaged?.takeRetainedValue() else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format
        ) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    // MARK: Touches

    private var geometry: DeviceScreenGeometry {
        DeviceScreenGeometry(
            screenWidth: screenSize.width, screenHeight: screenSize.height,
            viewWidth: bounds.width, viewHeight: bounds.height, orientation: orientation
        )
    }

    private func location(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard allowsInput else {
            onBlockedClick()
            return
        }
        window?.makeFirstResponder(self)
        let point = location(event)
        guard let touch = geometry.normalized(x: point.x, y: point.y) else { return }
        gestureStart = geometry.uprightClamped(x: point.x, y: point.y)
        send("begin", touch)
    }

    override func mouseDragged(with event: NSEvent) {
        guard lastTouch != nil else { return }
        let point = location(event)
        guard let touch = geometry.clamped(x: point.x, y: point.y) else { return }
        send("move", touch)
    }

    override func mouseUp(with event: NSEvent) {
        guard let last = lastTouch else { return }
        let point = location(event)
        send("end", geometry.clamped(x: point.x, y: point.y) ?? last)
        if let start = gestureStart, let end = geometry.uprightClamped(x: point.x, y: point.y) { onGesture?(start, end) }
        gestureStart = nil
        onUserInput()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = location(event)
        guard allowsInput, let udid, let at = geometry.normalized(x: point.x, y: point.y) else {
            super.scrollWheel(with: event)
            return
        }
        // A trackpad's deltas are points; a wheel's are lines, one step each.
        let scale = event.hasPreciseScrollingDeltas ? 0.1 : 1
        let (dx, dy) = (Double(event.scrollingDeltaX) * scale, Double(event.scrollingDeltaY) * scale)
        client?.scroll(udid: udid, point: at, dx: dx, dy: dy)
        // A simulator ignores the wheel: replaying it as a swipe would move what never moved.
        if client?.takesScroll == true { onScroll?(dx, dy) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(location(event))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    private func send(_ phase: String, _ touch: DeviceScreenPoint) {
        guard let udid else { return }
        lastTouch = phase == "end" ? nil : touch
        client?.touch(udid: udid, phase: phase, point: touch)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard allowsInput, !event.modifierFlags.contains(.command),
              HIDKeyboardUsage.usage(forKeyCode: event.keyCode) != nil else {
            super.keyDown(with: event)
            return
        }
        // Repeats come back nil: a simulator repeats a held key itself; others are told.
        if let key = heldKeys.keyDown(event.keyCode, command: false) {
            sendKey(key)
            if let characters = event.characters { onText?(characters) }
        } else if event.isARepeat, let udid, let usage = HIDKeyboardUsage.usage(forKeyCode: event.keyCode) {
            client?.keyRepeat(udid: udid, usage: usage)
            // The device typed it again (a simulator repeats on its own, at about the Mac's rate).
            if let characters = event.characters { onText?(characters) }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let key = heldKeys.keyUp(event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        sendKey(key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard allowsInput, HIDKeyboardUsage.usage(forModifierKeyCode: event.keyCode) != nil else {
            super.flagsChanged(with: event)
            return
        }
        if let key = heldKeys.modifierChanged(event.keyCode, modifierFlags: event.modifierFlags.rawValue) {
            sendKey(key)
        }
    }

    private func sendKey(_ key: HeldSimulatorKeys.Event) {
        guard let udid else { return }
        client?.key(udid: udid, usage: key.usage, down: key.down)
        if !key.down { onUserInput() }
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldInput()
        return super.resignFirstResponder()
    }

    /// Lifts a touch, key or modifier still down, so none stays stuck in the simulator.
    private func releaseHeldInput() {
        if let last = lastTouch { send("end", last) }
        heldKeys.releaseAll().forEach(sendKey)
    }
}

extension DeviceScreenNSView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(paste(_:)), #selector(copy(_:)): allowsInput && udid != nil
        default: true
        }
    }
}
