import AlasCore
import AppKit
import AVFoundation
import SwiftUI

struct NativePeerDevicesView: View {
    let manager: RemotePeerManager
    let serverId: String
    @State private var session: PeerDeviceSession?
    @State private var observer: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                PeerDeviceViewer(session: session)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: startViewing)
        .onDisappear(perform: stopViewing)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            session?.releaseControl()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            session?.releaseControl()
        }
    }

    private func startViewing() {
        guard session == nil else { return }
        let session = PeerDeviceSession(
            send: { [weak manager] in manager?.sendPeerDevice($0, serverId: serverId) },
            verifiedOrigin: { [weak manager] in manager?.verifiedDeviceOrigin(serverId: serverId) }
        )
        self.session = session
        observer = manager.observePeerDevices(serverId: serverId) { [weak session] update in
            switch update {
            case .connectionChanged: session?.connectionChanged()
            case .message(let event): session?.receive(event)
            }
        }
        session.refresh()
    }

    private func stopViewing() {
        if let observer { manager.removePeerDeviceObserver(observer, serverId: serverId) }
        observer = nil
        session?.close()
        session = nil
    }
}

private struct PeerDeviceViewer: View {
    let session: PeerDeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Menu {
                    ForEach(session.devices) { device in
                        Button {
                            session.select(device)
                        } label: {
                            Text(device.name)
                            if device.id == session.selected?.id { Image(systemName: "checkmark") }
                        }
                    }
                } label: {
                    Text(session.selected?.name ?? "Select a device")
                        .lineLimit(1)
                }
                .disabled(session.devices.isEmpty)
                .accessibilityLabel("Shared devices")
                Button("Refresh devices", systemImage: "arrow.clockwise", action: session.refresh)
                    .labelStyle(.iconOnly)
                    .help("Refresh devices or reopen the selected screen")
            }
            if session.selected == nil {
                Text(session.status ?? (session.hasDeviceList ? "No devices shared with this Mac." : "Looking for shared devices…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                PeerDeviceViewerStage(session: session)
            }
        }
        .padding(8)
    }
}

private struct PeerDeviceViewerStage: View {
    let session: PeerDeviceSession
    @State private var text = ""

    var body: some View {
        HStack {
            Text(driverStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if session.driver == .you {
                Button("Hand back", action: session.releaseControl)
            } else if session.canTakeControl {
                Button("Take over", action: session.takeControl)
            }
        }
        if let status = session.status ?? (session.playback.displayedSize != nil ? "Live" : nil) {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        PeerDeviceScreen(session: session)
            .accessibilityLabel("Android device screen")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        HStack(spacing: 4) {
            hardwareButton("Back", icon: "chevron.left", button: .back)
            hardwareButton("Home", icon: "house", button: .home)
            hardwareButton("Recents", icon: "square.on.square", button: .recents)
            hardwareButton("Power", icon: "power", button: .power)
            Spacer(minLength: 0)
        }
        .disabled(!session.canSendInput)
        HStack(spacing: 4) {
            TextField("Text to type on Android", text: $text)
                .onSubmit(sendText)
            Button("Send", action: sendText)
                .disabled(text.isEmpty || text.utf8.count > 4096)
        }
        .disabled(!session.canSendInput)
        .onChange(of: session.inputContext) { _, _ in text = "" }
    }

    private var driverStatus: String {
        let driver: String
        switch session.driver {
        case .available: driver = "No driver"
        case .you: driver = "You are driving"
        case .local: driver = "Driver: Host Mac"
        case .agent(let name), .other(let name): driver = "Driver: \(name)"
        }
        return session.selected?.access == .view ? "View only · \(driver)" : driver
    }

    private func hardwareButton(_ title: String, icon: String, button: PeerDeviceButton) -> some View {
        Button(title, systemImage: icon) { session.input(.button(button)) }
            .labelStyle(.iconOnly)
            .help(title)
    }

    private func sendText() {
        guard session.canSendInput, !text.isEmpty, text.utf8.count <= 4096 else { return }
        session.input(.text(text))
        text = ""
    }
}

private struct PeerDeviceScreen: NSViewRepresentable {
    let session: PeerDeviceSession

    func makeNSView(context: Context) -> PeerDeviceScreenView {
        PeerDeviceScreenView(session: session)
    }

    func updateNSView(_ view: PeerDeviceScreenView, context: Context) {
        view.syncInputContext()
    }

    static func dismantleNSView(_ view: PeerDeviceScreenView, coordinator: ()) {
        view.finishInput()
        view.session.playback.layer.removeFromSuperlayer()
    }
}

private final class PeerDeviceScreenView: NSView {
    let session: PeerDeviceSession
    private var remoteInputContext: PeerDeviceSession.InputContext?
    private var pointer: CGPoint?
    private var keys = HeldSimulatorKeys()

    init(session: PeerDeviceSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(session.playback.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.playback.layer.frame = bounds
        CATransaction.commit()
    }

    @discardableResult
    func syncInputContext() -> Bool {
        let live = session.inputContext
        if live != remoteInputContext {
            remoteInputContext = live
            pointer = nil
            keys = HeldSimulatorKeys()
        }
        return live != nil
    }

    override func mouseDown(with event: NSEvent) {
        guard syncInputContext(), let point = normalizedPoint(event) else { return }
        window?.makeFirstResponder(self)
        sendPointer(.begin, point: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard syncInputContext(), let pointer else { return }
        if let point = normalizedPoint(event) {
            sendPointer(.move, point: point)
        } else {
            sendPointer(.cancel, point: pointer)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard syncInputContext(), let pointer else { return }
        if let point = normalizedPoint(event) {
            sendPointer(.end, point: point)
        } else {
            sendPointer(.cancel, point: pointer)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard syncInputContext(), let point = normalizedPoint(event) else {
            super.scrollWheel(with: event)
            return
        }
        let scale = event.hasPreciseScrollingDeltas ? 0.1 : 1.0
        let dx = Double(event.scrollingDeltaX) * scale
        let dy = Double(event.scrollingDeltaY) * scale
        session.input(.scroll(x: point.x, y: point.y, dx: dx, dy: dy))
    }

    override func keyDown(with event: NSEvent) {
        guard syncInputContext(), !event.modifierFlags.contains(.command),
              HIDKeyboardUsage.usage(forKeyCode: event.keyCode) != nil else {
            super.keyDown(with: event)
            return
        }
        if let key = keys.keyDown(event.keyCode, command: false) { sendKey(key) }
    }

    override func keyUp(with event: NSEvent) {
        guard syncInputContext(), let key = keys.keyUp(event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        sendKey(key)
    }

    override func flagsChanged(with event: NSEvent) {
        guard syncInputContext(), HIDKeyboardUsage.usage(forModifierKeyCode: event.keyCode) != nil else {
            super.flagsChanged(with: event)
            return
        }
        if let key = keys.modifierChanged(event.keyCode, modifierFlags: event.modifierFlags.rawValue) { sendKey(key) }
    }

    override func resignFirstResponder() -> Bool {
        finishInput()
        return super.resignFirstResponder()
    }

    func finishInput() {
        guard syncInputContext() else { return }
        if let pointer { sendPointer(.cancel, point: pointer) }
        keys.releaseAll().forEach { sendKey($0) }
    }

    private func normalizedPoint(_ event: NSEvent) -> CGPoint? {
        guard let size = session.playback.displayedSize, !bounds.isEmpty else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let image = AVMakeRect(aspectRatio: size, insideRect: bounds)
        guard image.contains(point) else { return nil }
        return CGPoint(x: (point.x - image.minX) / image.width, y: (point.y - image.minY) / image.height)
    }

    private func sendPointer(_ phase: PeerDevicePointerPhase, point: CGPoint) {
        pointer = phase == .end || phase == .cancel ? nil : point
        session.input(.pointer(phase: phase, x: point.x, y: point.y))
    }

    private func sendKey(_ key: HeldSimulatorKeys.Event) {
        session.input(.key(usage: key.usage, down: key.down))
    }
}
