import AlasRemoteKit
import AVFoundation
import SwiftUI
import UIKit

struct PeerDevicesView: View {
    let hub: HostHub
    let host: PairedHost

    @Environment(\.dismiss) private var dismiss
    @State private var session: PeerDeviceSession?
    @State private var listener: ListenerToken?

    var body: some View {
        NavigationStack {
            Group {
                if let session, let device = session.selected {
                    PeerDeviceScreen(session: session, device: device, connectionProblem: connectionProblem)
                        .navigationTitle(device.name)
                } else if let session {
                    deviceList(session)
                        .navigationTitle("Devices")
                        .navigationSubtitle(host.name)
                } else {
                    ProgressView()
                        .navigationTitle("Devices")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session?.selected != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("All devices", systemImage: "chevron.left", action: showDeviceList)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        stop()
                        dismiss()
                    }
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private var connectionProblem: String? {
        switch hub.state(of: host.id) {
        case .online:
            if !hub.supports(PeerDeviceCapability.v1, on: host.id) {
                return "This Mac isn't sharing remote devices."
            }
            if hub.verifiedDeviceOrigin(of: host.id) == nil {
                return "Remote devices require a verified HTTPS connection."
            }
            return nil
        case .offline, .idle:
            return "Can't reach \(host.name)."
        case let state:
            return state.label
        }
    }

    private func deviceList(_ session: PeerDeviceSession) -> some View {
        List {
            if !session.devices.isEmpty, let notice = session.status {
                Text(notice)
                    .foregroundStyle(.secondary)
            }
            ForEach(session.devices) { device in
                Button {
                    session.select(device)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.headline)
                        Text(device.availability.peerDeviceStatus ?? device.driver.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(device.access == .control ? "View and control" : "View only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(connectionProblem != nil || device.availability != .ready)
            }
        }
        .overlay {
            if let connectionProblem {
                ContentUnavailableView("Remote devices unavailable", systemImage: "iphone.slash",
                                       description: Text(connectionProblem))
                    .background(.background)
            } else if !session.hasDeviceList {
                ProgressView("Loading devices…")
            } else if session.devices.isEmpty {
                ContentUnavailableView("No shared devices", systemImage: "iphone",
                                       description: Text(session.status ?? "Share a device from Remote settings on \(host.name)."))
            }
        }
        .refreshable { session.refresh() }
    }

    private func start() {
        guard session == nil else { return }
        let id = host.id
        let session = PeerDeviceSession(
            send: { [weak hub] request in
                guard let hub, hub.verifiedDeviceOrigin(of: id) != nil else { return }
                hub.send(.device(request), to: id)
            },
            verifiedOrigin: { [weak hub] in hub?.verifiedDeviceOrigin(of: id) }
        )
        listener = hub.addDeviceListener(id) { [weak session] event in
            switch event {
            case .connectionChanged: session?.connectionChanged()
            case .message(let message): session?.receive(message)
            }
        }
        self.session = session
        // HostHub also delivers the app's background disconnect here. The shared session
        // drops media and control on that edge, then reattaches view-only on a new link.
        session.refresh()
    }

    private func showDeviceList() {
        session?.close()
        session?.refresh()
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        session?.close()
        session = nil
    }
}

private struct PeerDeviceScreen: View {
    let session: PeerDeviceSession
    let device: PeerDeviceSummary
    let connectionProblem: String?

    @Environment(\.scenePhase) private var scenePhase

    private var status: String? {
        connectionProblem ?? session.status
            ?? (session.playback.displayedSize == nil ? "Waiting for video…" : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            PeerDeviceSurface(
                session: session, name: device.name, videoSize: session.playback.displayedSize,
                acceptsInput: scenePhase == .active && connectionProblem == nil && session.canSendInput
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PeerDeviceControls(session: session, status: status, connected: connectionProblem == nil)
        }
    }
}

private struct PeerDeviceControls: View {
    let session: PeerDeviceSession
    let status: String?
    let connected: Bool

    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: (context: PeerDeviceSession.InputContext, text: String)?
    @FocusState private var typing: Bool

    private var active: Bool { connected && scenePhase == .active }
    private var canSendInput: Bool { active && session.canSendInput }
    private static let maxTextBytes = 4096

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if connected {
                HStack {
                    Text(session.driver.label)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if active && session.driver == .you {
                        Button("Hand back", action: handBack)
                            .buttonStyle(.bordered)
                    } else if active && session.canTakeControl {
                        Button("Take over", action: session.takeControl)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            if canSendInput, let context = session.inputContext {
                let text = draftText(in: context)
                let tooLong = text.utf8.count > Self.maxTextBytes
                HStack {
                    deviceButton(.back, "Android Back", icon: "arrow.uturn.backward", context: context)
                    deviceButton(.home, "Android Home", icon: "house", context: context)
                    deviceButton(.recents, "Android Recents", icon: "square.on.square", context: context)
                    deviceButton(.power, "Android Power", icon: "power", context: context)
                }
                HStack {
                    TextField("Text to send", text: Binding(
                        get: { draftText(in: context) },
                        set: { draft = (context, $0) }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($typing)
                        .submitLabel(.send)
                        .onSubmit { sendText(in: context) }
                    Button("Send") { sendText(in: context) }
                        .disabled(text.isEmpty || tooLong)
                }
                if tooLong {
                    Text("Text is too long. Send it in smaller parts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .onChange(of: session.inputContext) { clearTextInput() }
        .onChange(of: canSendInput) { if !canSendInput { clearTextInput() } }
        .onChange(of: status ?? session.driver.label) { _, message in
            if UIAccessibility.isVoiceOverRunning {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }

    private func deviceButton(
        _ button: PeerDeviceButton, _ label: LocalizedStringKey, icon: String,
        context: PeerDeviceSession.InputContext
    ) -> some View {
        Button {
            guard canSendInput, context == session.inputContext else { return }
            session.input(.button(button))
        } label: {
            Label(label, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    private func draftText(in context: PeerDeviceSession.InputContext) -> String {
        guard let draft, draft.context == context else { return "" }
        return draft.text
    }

    private func sendText(in context: PeerDeviceSession.InputContext) {
        guard canSendInput, context == session.inputContext else { return }
        let text = draftText(in: context)
        guard !text.isEmpty, text.utf8.count <= Self.maxTextBytes else { return }
        session.input(.text(text))
        draft = nil
    }

    private func handBack() {
        clearTextInput()
        session.releaseControl()
    }

    private func clearTextInput() {
        typing = false
        draft = nil
    }
}

private struct PeerDeviceSurface: UIViewRepresentable {
    let session: PeerDeviceSession
    let name: String
    let videoSize: CGSize?
    let acceptsInput: Bool

    func makeUIView(context: Context) -> PeerDeviceTouchView {
        PeerDeviceTouchView(session: session)
    }

    func updateUIView(_ view: PeerDeviceTouchView, context: Context) {
        view.update(name: name, videoSize: videoSize, acceptsInput: acceptsInput)
    }

    static func dismantleUIView(_ view: PeerDeviceTouchView, coordinator: ()) {
        view.removeVideo()
    }
}

/// Tracks the original UITouch, not the first member of each event's touch set.
private final class PeerDeviceTouchView: UIView {
    private struct Contact {
        let touch: UITouch
        let context: PeerDeviceSession.InputContext
        var point: CGPoint
    }

    private let session: PeerDeviceSession
    private var videoSize: CGSize?
    private var videoRect: CGRect = .zero
    private var acceptsInput = false
    private var contact: Contact?

    init(session: PeerDeviceSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isMultipleTouchEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityDirectTouchOptions = .requiresActivation
        layer.addSublayer(session.playback.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(name: String, videoSize: CGSize?, acceptsInput: Bool) {
        if !acceptsInput || contact?.context != session.inputContext { cancelPointer() }
        if self.acceptsInput != acceptsInput {
            self.acceptsInput = acceptsInput
            accessibilityTraits = acceptsInput ? [.image, .allowsDirectInteraction] : .image
        }
        if self.videoSize != videoSize {
            cancelPointer()
            self.videoSize = videoSize
            videoRect = .zero
            setNeedsLayout()
        }
        accessibilityLabel = "\(name) screen"
        accessibilityValue = videoSize == nil ? "No video" : (acceptsInput ? "In control" : "View only")
    }

    func removeVideo() {
        cancelPointer()
        if session.playback.layer.superlayer === layer {
            session.playback.layer.removeFromSuperlayer()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = videoSize.map { AVMakeRect(aspectRatio: $0, insideRect: bounds) } ?? .zero
        if rect != videoRect {
            cancelPointer()
            videoRect = rect
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        session.playback.layer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelPointer() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsInput, contact == nil, let context = session.inputContext,
              videoSize == session.playback.displayedSize,
              let touch = touches.first, let point = normalizedPoint(for: touch),
              event?.touches(for: self)?.contains(where: { $0.phase == .moved || $0.phase == .stationary }) != true
        else { return }
        contact = Contact(touch: touch, context: context, point: point)
        send(.begin, point: point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        updatePointer(touches, phase: .move)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        updatePointer(touches, phase: .end)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let contact, touches.contains(contact.touch) { cancelPointer() }
    }

    private func updatePointer(_ touches: Set<UITouch>, phase: PeerDevicePointerPhase) {
        guard let contact, touches.contains(contact.touch) else { return }
        guard acceptsInput, contact.context == session.inputContext,
              let point = normalizedPoint(for: contact.touch) else {
            cancelPointer()
            return
        }
        if phase == .end {
            self.contact = nil
        } else {
            self.contact?.point = point
        }
        send(phase, point: point)
    }

    private func cancelPointer() {
        guard let contact else { return }
        self.contact = nil
        if contact.context == session.inputContext { send(.cancel, point: contact.point) }
    }

    private func normalizedPoint(for touch: UITouch) -> CGPoint? {
        let point = touch.location(in: self)
        guard !videoRect.isEmpty, videoRect.contains(point) else { return nil }
        return CGPoint(x: (point.x - videoRect.minX) / videoRect.width,
                       y: (point.y - videoRect.minY) / videoRect.height)
    }

    private func send(_ phase: PeerDevicePointerPhase, point: CGPoint) {
        session.input(.pointer(phase: phase, x: Double(point.x), y: Double(point.y)))
    }
}

private extension PeerDeviceDriver {
    var label: String {
        switch self {
        case .available: "No one is driving"
        case .agent(let name): "Agent driving: \(name)"
        case .local: "Someone on the host Mac is driving"
        case .you: "You're driving"
        case .other(let name): "\(name) is driving"
        }
    }
}
