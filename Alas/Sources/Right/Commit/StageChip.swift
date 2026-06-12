import SwiftUI

struct StageChip: View {
    enum DisplayState {
        case unstaged
        case staged
        case mixed
    }

    let state: DisplayState
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false

    init(staged: Bool, action: @escaping () -> Void) {
        self.state = staged ? .staged : .unstaged
        self.action = action
    }

    init(state: DisplayState, action: @escaping () -> Void) {
        self.state = state
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(border, lineWidth: 0.5)
                    )
                    .frame(width: 14, height: 14)
                Icon(name: glyph, size: 9, color: glyphColor)
            }
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .opacity(state != .unstaged || hovering ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var glyph: String {
        switch state {
        case .staged:
            return hovering ? "x" : "check"
        case .mixed:
            return hovering ? "plus" : "minus"
        case .unstaged:
            return "plus"
        }
    }

    private var glyphColor: Color {
        switch state {
        case .staged:
            return hovering ? theme.color("del") : theme.color("add")
        case .mixed:
            return hovering ? theme.color("fg") : theme.color("warn")
        case .unstaged:
            return hovering ? theme.color("fg") : theme.color("fg-faint")
        }
    }

    private var fill: Color {
        switch state {
        case .staged:
            return hovering
                ? theme.color("del").opacity(0.18)
                : theme.color("add").opacity(0.18)
        case .mixed:
            return hovering
                ? theme.color("bg-4")
                : theme.color("warn").opacity(0.16)
        case .unstaged:
            return hovering ? theme.color("bg-4") : .clear
        }
    }

    private var border: Color {
        switch state {
        case .staged:
            return hovering
                ? theme.color("del").opacity(0.5)
                : theme.color("add").opacity(0.5)
        case .mixed:
            return hovering ? theme.color("fg-dim") : theme.color("warn").opacity(0.5)
        case .unstaged:
            return hovering ? theme.color("fg-dim") : theme.color("line")
        }
    }

    private var help: String {
        switch state {
        case .staged: return "Unstage"
        case .mixed: return "Stage remaining changes"
        case .unstaged: return "Stage"
        }
    }
}
