import SwiftUI

struct ApprovalPresentation {
    let title: String
    let detail: String
    let allowsDecision: Bool
    let remainingSeconds: Int

    init(entry: RemotePairingApprovalCoordinator.Entry, now: Date) {
        let name = String(ApprovalWire.displayName(entry.payload.requester.name).prefix(200))
        let deadline = Date(timeIntervalSince1970: Double(entry.payload.expiresAtMilliseconds) / 1_000)
        remainingSeconds = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        allowsDecision = entry.phase == .pending && remainingSeconds > 0
        switch entry.phase {
        case .challenged, .pending:
            title = "\"\(name)\" wants to pair"
            detail = "Allow these Macs to view and control each other's sessions.\nDevice name supplied by the requester."
        case .approved, .redeeming:
            title = "Pairing with \(name)…"
            detail = "Waiting for both Macs to confirm pairing."
        case .paired:
            title = "Paired with \(name)"
            detail = "Both Macs confirmed pairing."
        case .failed:
            title = "Couldn't pair with \(name)"
            detail = "Pairing failed. Start a new request from the other Mac to try again."
        case .expired:
            title = "Pairing request expired"
            detail = "Start a new request from \(name) to try again."
        case .declined:
            title = "Pairing request declined"
            detail = name
        case .cancelled:
            title = "Pairing request cancelled"
            detail = name
        }
    }
}

struct ApprovalStackHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ApprovalContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ApprovalNotificationInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var approvalNotificationInset: CGFloat {
        get { self[ApprovalNotificationInsetKey.self] }
        set { self[ApprovalNotificationInsetKey.self] = newValue }
    }
}

struct RemotePairingApprovalStack: View {
    let coordinator: RemotePairingApprovalCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var contentHeight: CGFloat = 0

    private var entries: [RemotePairingApprovalCoordinator.Entry] {
        let pending = coordinator.entries.filter { $0.phase == .pending }
        let completing = coordinator.entries.filter { [.approved, .redeeming].contains($0.phase) }
        let completed = coordinator.entries.filter { [.paired, .failed].contains($0.phase) }
        return Array((pending + completing + completed).prefix(3))
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(entries) { entry in
                    RemotePairingApprovalCard(entry: entry,
                        allow: { coordinator.decide(.allow, requestID: entry.id) },
                        decline: { coordinator.decide(.decline, requestID: entry.id) })
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ApprovalContentHeightKey.self, value: geometry.size.height)
                }.allowsHitTesting(false)
            }
            .frame(maxHeight: 420, alignment: .bottom)
            .onPreferenceChange(ApprovalContentHeightKey.self) { contentHeight = $0 }
            .preference(key: ApprovalStackHeightKey.self, value: min(contentHeight, 420))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: entries.map(\.id))
        }
    }
}

struct RemotePairingApprovalCard: View {
    let entry: RemotePairingApprovalCoordinator.Entry
    let allow: () -> Void
    let decline: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = ApprovalPresentation(entry: entry, now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(presentation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.phase == .pending {
                        Button(action: decline) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.color("fg-muted"))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Decline pairing request")
                        .disabled(!presentation.allowsDecision)
                    }
                }
                Text(presentation.detail)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.phase == .pending {
                    HStack {
                        Text("\(presentation.remainingSeconds)s remaining")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-muted"))
                            .accessibilityLabel("\(presentation.remainingSeconds) seconds remaining to decide")
                        Spacer()
                        Button("Decline", action: decline)
                            .accessibilityLabel("Decline pairing request")
                        Button("Allow", action: allow)
                            .accessibilityLabel("Allow these Macs to view and control each other's sessions")
                    }
                    .foregroundStyle(theme.color("accent"))
                    .font(.system(size: 12))
                    .disabled(!presentation.allowsDecision)
                }
            }
            .foregroundStyle(theme.color("fg"))
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(theme.color("accent").opacity(0.12).background(theme.color("bg-1")))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.color("accent").opacity(0.3), lineWidth: 0.75))
            .compositingGroup()
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("peer-pairing-approval-card")
        }
    }
}
