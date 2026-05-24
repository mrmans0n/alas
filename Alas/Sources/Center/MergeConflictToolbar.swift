import SwiftUI

struct MergeConflictToolbar: View {
    let conflictCount: Int
    let currentConflictIndex: Int?
    @Binding var showBase: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onAcceptLocal: () -> Void
    let onAcceptRemote: () -> Void
    let onAcceptBoth: () -> Void
    let onAcceptAndNext: () -> Void
    let onMarkResolved: () -> Void

    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 8) {
            counter
            Divider().frame(height: 18)
            navigationButtons
            Divider().frame(height: 18)
            acceptButtons
            Spacer()
            Toggle("Show BASE", isOn: $showBase)
                .toggleStyle(.button)
                .controlSize(.small)
            Button(action: onMarkResolved) {
                Text("Mark resolved")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(conflictCount > 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.color("bg-1"))
        .overlay(Divider(), alignment: .bottom)
    }

    private var counter: some View {
        Text(counterText)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-dim"))
    }

    private var counterText: String {
        if conflictCount == 0 {
            return "All resolved"
        }
        if let idx = currentConflictIndex {
            return "Conflict \(idx + 1) of \(conflictCount)"
        }
        return "\(conflictCount) conflict(s)"
    }

    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .keyboardShortcut(.upArrow, modifiers: [.option])
                .help("Previous conflict (⌥↑)")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .keyboardShortcut(.downArrow, modifiers: [.option])
                .help("Next conflict (⌥↓)")
            Button(action: onAcceptAndNext) {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                    Image(systemName: "chevron.down")
                }
            }
            .keyboardShortcut(.return, modifiers: [.option])
            .help("Accept LOCAL and jump to next (⌥↵)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(conflictCount == 0)
    }

    private var acceptButtons: some View {
        HStack(spacing: 4) {
            Button("Use LOCAL", action: onAcceptLocal)
                .keyboardShortcut("[", modifiers: [.command, .option])
                .help("Accept LOCAL for current conflict (⌥⌘[)")
            Button("Use REMOTE", action: onAcceptRemote)
                .keyboardShortcut("]", modifiers: [.command, .option])
                .help("Accept REMOTE for current conflict (⌥⌘])")
            Button("Use BOTH", action: onAcceptBoth)
                .help("Accept LOCAL then REMOTE")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(conflictCount == 0)
    }
}
