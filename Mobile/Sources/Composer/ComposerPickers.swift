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
                    CommandCap(isAlas: command.command == ChipActions.ship.command)
                } action: {
                    pick(command)
                }
                .overlay(alignment: .trailing) {
                    if command.skill != nil {
                        Text("Skill").font(.caption2).foregroundStyle(.tertiary).padding(.trailing, 16)
                    }
                }
            }
        }
    }
}

/// The Mac remote composer's scopes: no Symbols, which a peer doesn't search.
private enum MentionScope: String, CaseIterable {
    case all = "All", files = "Files", sessions = "Sessions"

    func admits(_ mention: RemoteMention) -> Bool {
        switch self {
        case .all: true
        case .files: mention.kind == RemoteMention.file
        case .sessions: mention.kind == RemoteMention.session
        }
    }
}

struct MentionPicker: View {
    let candidates: [RemoteMention]
    /// A newer query is in flight; `candidates` answer an older one.
    let searching: Bool
    let pick: (RemoteMention) -> Void
    @State private var scope = MentionScope.all

    var body: some View {
        let shown = candidates.filter(scope.admits)
        VStack(spacing: 6) {
            Picker("Scope", selection: $scope) {
                ForEach(MentionScope.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            PickerList {
                ForEach(shown, id: \.self) { mention in
                    PickerRow(title: mention.name, detail: mention.detail, mono: mention.kind == RemoteMention.file) {
                        Image(systemName: MentionCard.icon(kind: mention.kind, name: mention.value))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                    } action: {
                        pick(mention)
                    }
                    .allowsHitTesting(!searching)
                }
                if shown.isEmpty {
                    Text(searching ? "Searching…" : "No matches")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 9)
                }
            }
            .opacity(searching ? 0.5 : 1)
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

private struct PickerRow<Leading: View>: View {
    let title: String
    let detail: String?
    let mono: Bool
    @ViewBuilder let leading: Leading
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(mono ? .subheadline.monospaced() : .subheadline)
                        .lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
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

/// A command row's wand cap, with the prism on a command Alas runs itself.
private struct CommandCap: View {
    let isAlas: Bool

    var body: some View {
        Image(systemName: "wand.and.sparkles")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background {
                if isAlas { PrismBackground() } else { Color(ChipStyle.commandTint).opacity(0.55) }
            }
            .clipShape(.rect(cornerRadius: ChipStyle.radius))
            .accessibilityHidden(true)
    }
}
