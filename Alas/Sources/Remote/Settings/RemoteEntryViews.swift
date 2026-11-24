import SwiftUI

/// A short tag beside a remote entry's name, for the one thing about it that
/// needs a look: agent access that is not off, a host older than this app.
struct RemoteEntryChip: Equatable, Identifiable {
    let text: String
    var isWarning = false
    var id: String { text }
}

/// One paired Mac, phone or browser in Settings › Remote, shaped like a
/// Machines row: a tile with its presence, the name, one line of state, and
/// Edit… for everything else.
struct RemoteEntryRow<Tile: View>: View {
    let name: String
    let summary: String
    var chips: [RemoteEntryChip] = []
    let onEdit: () -> Void
    @ViewBuilder let tile: () -> Tile
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        // Two columns, as `SettingsRow` and the Machines list lay out, so
        // Edit… lines up with every other control in the pane.
        HStack(spacing: SettingsRowLayout.columnSpacing) {
            HStack(spacing: scale.space[3]) {
                tile()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: scale.space[2]) {
                        Text(name)
                            .font(scale.emphasisFont)
                            .foregroundColor(theme.color("fg"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        ForEach(chips) { chip in
                            Text(chip.text)
                                .font(scale.caption.font(weight: .semibold))
                                .foregroundColor(theme.color(chip.isWarning ? "warn" : "fg-dim"))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(theme.color(chip.isWarning ? "warn" : "fg-dim").opacity(0.14), in: Capsule())
                                .fixedSize()
                        }
                    }
                    Text(summary)
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AlasButton(title: "Edit…", style: .subtle, action: onEdit)
                .accessibilityLabel("Edit \(name)")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, scale.space[3])
        .overlay(Divider().opacity(0.5), alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

/// The sheet an entry's Edit… opens: a header naming it, labelled sections,
/// and a footer with the destructive action apart from Done.
struct RemoteEntrySheet<Tile: View, Content: View>: View {
    let title: String
    let subtitle: String
    let destructiveTitle: String?
    let onDestructive: () -> Void
    let onDone: () -> Void
    @ViewBuilder let tile: () -> Tile
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: scale.space[3]) {
                tile()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold)) // design-literal: the one dialog title
                    Text(subtitle)
                        .font(scale.metaFont)
                        .foregroundColor(theme.color("fg-dim"))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.bottom, scale.space[2])
            content()
            HStack {
                if let destructiveTitle {
                    AlasButton(title: destructiveTitle, style: .subtle, tint: theme.color("warn"), action: onDestructive)
                }
                Spacer(minLength: 0)
                AlasButton(title: "Done", style: .primary, action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, scale.space[4])
        }
        .padding(scale.space[5])
        .frame(width: 480)
        .background(theme.color("bg-1"))
    }
}

/// A labelled group inside a `RemoteEntrySheet`.
struct RemoteEntrySheetSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(scale.caption.font(weight: .semibold))
                .tracking(0.6)
                .foregroundColor(theme.color("fg-dim"))
                .padding(.top, scale.space[4])
                .padding(.bottom, scale.space[1])
            content()
        }
    }
}

/// A label and its value on one line of a `RemoteEntrySheetSection`.
struct RemoteEntryFact: View {
    let label: String
    let value: String
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale.space[3]) {
            Text(label)
                .foregroundColor(theme.color("fg-dim"))
                .frame(width: 110, alignment: .leading)
            Text(value)
                .foregroundColor(theme.color("fg"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(scale.metaFont)
        .padding(.vertical, scale.space[1])
    }
}
