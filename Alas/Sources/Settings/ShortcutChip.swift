import SwiftUI

struct ShortcutChip: View {
    @Environment(\.designScale) private var scale
    let binding: ShortcutBinding?     // nil = unbound
    let isRecording: Bool
    let justModified: Bool
    let liveModifiers: [ShortcutBinding.Modifier]   // shown during recording
    var onClick: () -> Void
    var onClear: () -> Void

    @Environment(\.theme) var theme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.custom("JetBrainsMonoNF-Regular", size: scale.meta.size))
                .foregroundColor(textColor)
            if showClear {
                Button(action: onClear) {
                    Image(systemName: "xmark")
                        .font(scale.glyphFont)
                        .foregroundColor(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .padding(.leading, scale.space[0])
            }
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[1])
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
        .overlay(border)
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onClick() }
    }

    private var label: String {
        if isRecording {
            if liveModifiers.isEmpty { return "Press keys…" }
            let order: [ShortcutBinding.Modifier] = [.control, .option, .shift, .command]
            return order.filter { liveModifiers.contains($0) }
                .map { symbol(for: $0) }.joined(separator: " ")
        }
        if let binding { return binding.displayString }
        return "Not set"
    }

    private func symbol(for m: ShortcutBinding.Modifier) -> String {
        switch m {
        case .control: return "⌃"
        case .option:  return "⌥"
        case .shift:   return "⇧"
        case .command: return "⌘"
        }
    }

    private var textColor: Color {
        if isRecording { return Color.black }
        if binding == nil { return theme.color("fg-faint") }
        return theme.color("fg")
    }

    private var background: Color {
        if isRecording { return theme.color("accent") }
        return theme.color("bg-3")
    }

    @ViewBuilder
    private var border: some View {
        RoundedRectangle(cornerRadius: scale.radius.small)
            .strokeBorder(
                justModified ? theme.color("accent") : Color.black.opacity(0.25),
                lineWidth: justModified ? 1.5 : 0.5
            )
    }

    private var showClear: Bool {
        isHovering && binding != nil && !isRecording
    }
}
