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

    func makeNSView(context: Context) -> DeviceScreenNSView {
        let view = DeviceScreenNSView()
        view.onStopped = onStopped
        view.attach(udid: udid, client: client)
        return view
    }

    func updateNSView(_ view: DeviceScreenNSView, context: Context) {
        view.onStopped = onStopped
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
    private var heldModifiers: Set<UInt16> = []
    var onStopped: (String) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        guard !event.modifierFlags.contains(.command),
              let usage = HIDKeyboardUsage.usage(forKeyCode: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        // The simulator repeats a held key itself.
        guard !event.isARepeat, let udid else { return }
        client?.key(udid: udid, usage: usage, down: true)
    }

    override func keyUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command),
              let usage = HIDKeyboardUsage.usage(forKeyCode: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        guard let udid else { return }
        client?.key(udid: udid, usage: usage, down: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let usage = HIDKeyboardUsage.usage(forModifierKeyCode: event.keyCode), let udid else {
            super.flagsChanged(with: event)
            return
        }
        let down = heldModifiers.insert(event.keyCode).inserted
        if !down { heldModifiers.remove(event.keyCode) }
        client?.key(udid: udid, usage: usage, down: down)
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldInput()
        return super.resignFirstResponder()
    }

    /// Lifts a touch or modifier still down, so none stays stuck in the simulator.
    private func releaseHeldInput() {
        guard let udid else { return }
        if let last = lastTouch { send("end", last) }
        for keyCode in heldModifiers {
            if let usage = HIDKeyboardUsage.usage(forModifierKeyCode: keyCode) {
                client?.key(udid: udid, usage: usage, down: false)
            }
        }
        heldModifiers.removeAll()
    }
}
