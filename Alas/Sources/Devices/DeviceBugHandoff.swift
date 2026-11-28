import AlasCore
import CoreGraphics
import ImageIO
import IOSurface
import SwiftUI
import UniformTypeIdentifiers

/// The video is copied into an upright, independently owned image before drawing a selection.
@MainActor @Observable
final class DeviceBugCapture: Identifiable {
    let image: CGImage
    let overview: Data
    let name: String
    let runtime: String
    private let frameSize: CGSize
    private let orientation: DeviceScreenOrientation
    private let fingerprint: DeviceFrameFingerprint?
    private(set) var appID: String?
    private(set) var snapshot: DeviceSnapshot?

    init?(frame: DeviceFrame, name: String, runtime: String) {
        guard let png = DeviceScreenshot.png(frame, maxLongEdge: 1280),
              let source = CGImageSourceCreateWithData(png.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.overview = png.data
        self.image = image
        self.name = name
        self.runtime = runtime
        frameSize = CGSize(width: frame.surface.width, height: frame.surface.height)
        orientation = frame.orientation
        fingerprint = DeviceFrameFingerprint(frame.surface)
    }

    var pixels: CGSize { CGSize(width: image.width, height: image.height) }

    func readContext(from backend: any DeviceBackend, deviceID: String) async {
        let app = await backend.frontApp(deviceID)
        guard !Task.isCancelled else { return }
        let tree = try? await backend.snapshot(deviceID, generation: 0)
        // A decoded video can vary on a still screen. Use the same comparison as device settling.
        guard !Task.isCancelled, let fingerprint, let current = backend.input.lastFrame(udid: deviceID),
              current.orientation == orientation,
              CGSize(width: current.surface.width, height: current.surface.height) == frameSize,
              let currentFingerprint = DeviceFrameFingerprint(current.surface),
              fingerprint.matches(currentFingerprint) else { return }
        appID = app
        snapshot = tree
    }

    func croppedPNG(_ crop: CGImage) -> Data? {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, crop, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return bytes as Data
    }
}

/// Same-worktree ACP chats. When the device is in a checkout, include that checkout's chats too.
@MainActor
struct DeviceBugRecipients {
    struct Chat: Identifiable {
        let id: String
        let owner: SessionOwnerID
        let title: String
    }

    let state: AppState
    let worktreeID: String

    var chats: [Chat] {
        var owners: [SessionOwnerID] = [.worktree(worktreeID)]
        if state.checkoutFocusedWorktreeScope?.worktreeID == worktreeID, let checkout = state.selectedWorkspaceCheckout {
            owners.append(.workspaceCheckout(checkout.id, checkout.executionLocation))
        }
        return owners.flatMap { owner in
            let scope = owner.worktreeID == nil ? "Workspace chat" : "Worktree chat"
            let tabs = state.tabs.tabs(for: owner).compactMap { tab -> ACPSessionTabState? in
                if case .acpSession(let chat) = tab { return chat }
                return nil
            }
            let manager = state.acpManager(for: owner)
            return tabs.enumerated().compactMap { index, chat -> Chat? in
                let session = manager?.liveSession(for: chat.sessionId)
                let row = manager?.cachedPersistedSessionRow(id: chat.sessionId)
                if let runtime = session?.runtimeKind ?? row?.runtimeKind, runtime != .v1 { return nil }
                let agent = (session?.agentId ?? row?.agentId).flatMap { state.agent(id: $0)?.displayName }
                let context = "\(scope) \(index + 1)"
                let title = [chat.title.isEmpty ? nil : chat.title, agent, context].compactMap { $0 }.joined(separator: " · ")
                return Chat(id: chat.sessionId, owner: owner, title: title)
            }
        }
    }

    func show(_ chat: Chat) {
        if let worktreeID = chat.owner.worktreeID, let worktree = state.worktree(withId: worktreeID) {
            state.activateHarnessSession(projectId: worktree.projectId, worktreeId: worktreeID, sessionId: chat.id)
        } else {
            state.activateHarnessSession(owner: chat.owner, sessionId: chat.id)
        }
    }

    func send(
        text: String, images: [(name: String, data: Data)], to chat: Chat,
        onAccepted: @escaping @MainActor () -> Void, onRejected: @escaping @MainActor (String) -> Void
    ) async {
        await state.prepareACPSessionForPrompt(sessionId: chat.id, owner: chat.owner)
        let stillOpen: @MainActor @Sendable () -> Bool = {
            self.chats.contains { $0.id == chat.id && $0.owner == chat.owner }
        }
        guard !Task.isCancelled, let manager = state.acpManager(for: chat.owner),
              let session = manager.liveSession(for: chat.id) else {
            return onRejected("This chat is no longer available in this worktree.")
        }
        guard session.runtimeKind == .v1, manager.executionRemoteHost == nil || session.imageInputSupported else {
            return onRejected("This chat can't receive image attachments. Choose another chat.")
        }
        guard stillOpen() else { return onRejected("This chat is no longer available in this worktree.") }
        let attachments: [ACPMessage.Attachment]
        do {
            attachments = try images.map { image in
                let staged = try ACPImageStaging.stage(data: image.data, into: chat.owner.storageKey)
                return ACPMessage.Attachment(uri: staged.url.absoluteString, name: image.name, mimeType: staged.mimeType)
            }
        } catch {
            return onRejected("Couldn't attach the device images.")
        }
        var accepted = false
        await manager.sendPrompt(
            for: chat.id, text: text, attachments: attachments,
            isStillWanted: stillOpen,
            onAccepted: {
                accepted = true
                onAccepted()
            }
        ) { delivered in
            if !accepted, !delivered { onRejected("The chat didn't accept this report. Check the chat and try again.") }
        }
    }
}

struct DeviceBugHandoffSheet: View {
    let capture: DeviceBugCapture
    let recipients: DeviceBugRecipients
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var crop: CGRect?
    @State private var preview: CGImage?
    @State private var note = ""
    @State private var chatID: String?
    @State private var error: String?
    @State private var sending = false

    private var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var target: DeviceElement? {
        guard preview != nil, let crop, let snapshot = capture.snapshot else { return nil }
        return DeviceBugSelection.target(in: crop, pixels: capture.pixels, snapshot: snapshot)
    }

    private var metadata: String {
        var lines = ["Device: \(capture.name) (\(capture.runtime))"]
        if let app = capture.appID { lines.append("App: \(app)") }
        if let target {
            lines.append("Accessibility role: \(target.role)")
            // Some providers expose current field contents in the label.
            let role = target.role.lowercased()
            if !role.contains("field"), role != "edit text", role != "text view", let label = target.label {
                lines.append("Label: \(label)")
            }
            if let id = target.id { lines.append("Accessibility ID: \(id)") }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        let chats = recipients.chats
        let selected = chats.first(where: { $0.id == chatID })
        VStack(alignment: .leading, spacing: scale.space[3]) {
            Text("Send device bug to agent").font(.headline)
            Text("Drag a rectangle on the frozen screen. Review what will be sent to the selected chat.")
                .foregroundStyle(theme.color("fg-dim"))
            HStack(alignment: .top, spacing: scale.space[4]) {
                frozenScreen
                    .frame(width: 320, height: 400)
                VStack(alignment: .leading, spacing: scale.space[2]) {
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 108)
                            .accessibilityLabel("Selected crop")
                    }
                    Text(metadata)
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg-dim"))
                        .lineLimit(5)
                    TextField("What went wrong?", text: $note, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(4...6)
                    if chats.isEmpty {
                        Text("Open an agent chat in this worktree, then try again.")
                            .foregroundStyle(theme.color("fg-dim"))
                    } else {
                        Picker("Agent chat", selection: $chatID) {
                            Text("Choose a chat").tag(nil as String?)
                            ForEach(chats) { chat in Text(chat.title).tag(Optional(chat.id)) }
                        }
                    }
                    if let error { Text(error).foregroundStyle(theme.color("warn")) }
                }
                .frame(width: 270, alignment: .leading)
            }
            .disabled(sending)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(sending)
                Button("Send to agent") {
                    if let selected { send(to: selected) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sending || selected == nil || preview == nil || trimmedNote.isEmpty)
            }
        }
        .padding(scale.space[5])
        .onAppear { if chats.count == 1 { chatID = chats.first?.id } }
        .interactiveDismissDisabled(sending)
    }

    private var frozenScreen: some View {
        GeometryReader { geometry in
            let screen = DeviceBugSelection.fitted(capture.pixels, in: geometry.size)
            let scale = screen.width / capture.pixels.width
            ZStack(alignment: .topLeading) {
                theme.color("bg-1")
                Image(decorative: capture.image, scale: 1)
                    .resizable()
                    .frame(width: screen.width, height: screen.height)
                    .offset(x: screen.minX, y: screen.minY)
                    .accessibilityHidden(true)
                if let crop {
                    Rectangle()
                        .fill(theme.color("accent").opacity(0.2))
                        .overlay { Rectangle().strokeBorder(theme.color("accent"), lineWidth: 2) }
                        .frame(width: crop.width * scale, height: crop.height * scale)
                        .offset(x: screen.minX + crop.minX * scale, y: screen.minY + crop.minY * scale)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Frozen device screen")
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { drag in
                    crop = DeviceBugSelection.crop(from: drag.startLocation, to: drag.location, pixels: capture.pixels, view: geometry.size)
                    preview = nil
                }
                .onEnded { drag in
                    crop = DeviceBugSelection.crop(from: drag.startLocation, to: drag.location, pixels: capture.pixels, view: geometry.size)
                    preview = crop.flatMap { capture.image.cropping(to: $0) }
                })
            .accessibilityAction(named: "Select the whole screen") {
                crop = CGRect(origin: .zero, size: capture.pixels)
                preview = capture.image
            }
        }
    }

    private func send(to chat: DeviceBugRecipients.Chat) {
        guard !sending, let preview, let cropped = capture.croppedPNG(preview) else {
            error = "Couldn't crop the frozen screen. Draw the selection again."
            return
        }
        let text = "Device bug report\n\n\(trimmedNote)\n\n\(metadata)\n\nImages: frozen screen overview, then selected region."
        sending = true
        error = nil
        Task {
            await recipients.send(text: text, images: [("Device screen", capture.overview), ("Selected region", cropped)], to: chat) {
                dismiss()
                recipients.show(chat)
            } onRejected: { reason in
                error = reason
                sending = false
            }
        }
    }
}
