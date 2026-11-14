import AlasRemoteKit
import SwiftUI

/// The `/` and `@` suggestion lists, floating above the bar.
struct SlashPicker: View {
    let commands: [RemoteSlashCommand]
    let pick: (RemoteSlashCommand) -> Void

    var body: some View {
        PickerList {
            ForEach(commands, id: \.command) { command in
                PickerRow(title: command.command, detail: command.description ?? command.hint, mono: true) {
                    pick(command)
                }
            }
        }
    }
}

struct MentionPicker: View {
    let candidates: [RemoteMention]
    let pick: (RemoteMention) -> Void

    var body: some View {
        PickerList {
            ForEach(candidates, id: \.self) { mention in
                PickerRow(title: mention.name, detail: mention.detail, mono: mention.kind == RemoteMention.file) {
                    pick(mention)
                }
            }
        }
    }
}

private struct PickerList<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) { content }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct PickerRow: View {
    let title: String
    let detail: String?
    let mono: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(mono ? .subheadline.monospaced() : .subheadline)
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
