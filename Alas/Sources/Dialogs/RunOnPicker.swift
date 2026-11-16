import SwiftUI

/// New Worktree's choice of where the worktree runs: this Mac or a Machine.
struct RunOnPicker: View {
    @Environment(\.designScale) private var scale
    @Environment(\.theme) private var theme
    /// The chosen Machine's destination; nil for this Mac.
    @Binding var selection: String?
    let options: [RunOnOption]
    @State private var open = false

    private var selected: RunOnOption? { options.first { $0.host == selection } }

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 6) {
                if let selected { reachabilityDot(selected) }
                Text(selected?.label ?? "This Mac")
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(scale.glyphFont)
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, scale.space[2])
            .frame(height: 28)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Run on")
        .accessibilityValue(selected?.label ?? "This Mac")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { row($0) }
                Divider().background(theme.color("line"))
                Button(action: {
                    open = false
                    NotificationCenter.default.post(name: .alasOpenSettings, object: SettingsSection.machines)
                }) {
                    Text("Add machine…")
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-muted"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, scale.space[3])
                        .padding(.vertical, scale.space[2])
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 340)
        }
    }

    private func row(_ option: RunOnOption) -> some View {
        Button(action: {
            selection = option.host
            open = false
        }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .opacity(option.host == selection ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(scale.metaFont)
                            .foregroundColor(theme.color("fg"))
                        reachabilityDot(option)
                    }
                    Text(option.disabledReason ?? option.detail)
                        .font(scale.captionFont)
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[2])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(option.disabledReason != nil)
        .opacity(option.disabledReason == nil ? 1 : 0.5)
        .help(option.disabledReason ?? option.detail)
    }

    @ViewBuilder
    private func reachabilityDot(_ option: RunOnOption) -> some View {
        if case .ready(_, let reachability) = option.kind {
            Circle()
                .fill(theme.color(reachability == .online ? "add" : reachability == .offline ? "warn" : "fg-faint"))
                .frame(width: 6, height: 6)
                .accessibilityLabel(reachability == .online ? "Online" : reachability == .offline ? "Offline" : "Not checked yet")
        }
    }
}
