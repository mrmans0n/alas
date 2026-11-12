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
    let client: SimulatorStreamClient
    var onStopped: (String) -> Void
    /// False while an agent drives: clicks and keys stay off the simulator.
    var allowsInput = true
    var onBlockedClick: () -> Void = {}
    /// A dropped `.app` the simulator can run.
    var onDropApp: (URL) -> Void = { _ in }
    /// Whether such a drag is over the screen.
    var onDropTargeted: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DeviceScreenNSView {
        let view = DeviceScreenNSView()
        view.onStopped = onStopped
        view.onBlockedClick = onBlockedClick
        view.onDropApp = onDropApp
        view.onDropTargeted = onDropTargeted
        view.allowsInput = allowsInput
        view.attach(udid: udid, client: client)
        return view
    }

    func updateNSView(_ view: DeviceScreenNSView, context: Context) {
        view.onStopped = onStopped
        view.onBlockedClick = onBlockedClick
        view.onDropApp = onDropApp
        view.onDropTargeted = onDropTargeted
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
    private weak var client: SimulatorStreamClient?
    private var token: UUID?
    private var screenSize = CGSize.zero
    private var lastTouch: DeviceScreenPoint?
    private var heldKeys = HeldSimulatorKeys()
    var onStopped: (String) -> Void = { _ in }
    var onBlockedClick: () -> Void = {}
    var onDropApp: (URL) -> Void = { _ in }
    var onDropTargeted: (Bool) -> Void = { _ in }
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

    /// One `.app` the simulator can run; anything else isn't offered a drop.
    private func droppedApp(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, urls.count == 1, (try? SimulatorAppBundle.read(urls[0])) != nil else { return nil }
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
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(udid: String, client: SimulatorStreamClient) {
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
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    // MARK: Frames

    private func show(_ surface: IOSurface) {
        screenSize = CGSize(width: surface.width, height: surface.height)
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
            viewWidth: bounds.width, viewHeight: bounds.height
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
        // Repeats come back nil: the simulator repeats a held key itself.
        if let key = heldKeys.keyDown(event.keyCode, command: false) { sendKey(key) }
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
