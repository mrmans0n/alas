import SwiftUI

struct StageChip: View {
    let staged: Bool
    let action: () -> Void
    @Environment(\.theme) var theme
    @State private var hovering = false

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
            .opacity(staged || hovering ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(staged ? "Unstage" : "Stage")
    }

    private var glyph: String {
        if staged { return hovering ? "x" : "check" }
        return "plus"
    }

    private var glyphColor: Color {
        if staged {
            return hovering ? theme.color("del") : theme.color("add")
        }
        return hovering ? theme.color("fg") : theme.color("fg-faint")
    }

    private var fill: Color {
        if staged {
            return hovering
                ? theme.color("del").opacity(0.18)
                : theme.color("add").opacity(0.18)
        }
        return hovering ? theme.color("bg-4") : .clear
    }

    private var border: Color {
        if staged {
            return hovering
                ? theme.color("del").opacity(0.5)
                : theme.color("add").opacity(0.5)
        }
        return hovering ? theme.color("fg-dim") : theme.color("line")
    }
}
