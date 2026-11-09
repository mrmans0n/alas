import SwiftUI

struct SearchInputRow: View {
    @Bindable var model: SearchModel
    @FocusState.Binding var inputFocused: Bool
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(scale.meta.font(weight: .regular))
                .foregroundColor(theme.color("fg-dim"))
            TextField(placeholderText, text: $model.query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 15)) // design-literal: search query field
                .foregroundColor(theme.color("fg"))
                .autocorrectionDisabled(true)
            if model.isLoading {
                Spinner(lineWidth: 1.5, duration: 0.7)
                    .frame(width: 12, height: 12)
                    .accessibilityLabel("Searching")
            }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(scale.glyph.font(weight: .bold))
                        .frame(width: 18, height: 18)
                        .foregroundColor(theme.color("fg-dim"))
                        .background(Circle().fill(theme.color("bg-3")))
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 0) {
                tab("Files",   .files)
                tab("Content", .content)
            }
            .padding(scale.space[0])
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous))
        }
        .padding(.horizontal, scale.space[4])
        .padding(.vertical, scale.space[3])
        .overlay(
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var placeholderText: String {
        switch model.kind {
        case .files:   return "Search files by name…"
        case .content: return "Search file contents…"
        }
    }

    @ViewBuilder
    private func tab(_ label: String, _ k: SearchKind) -> some View {
        let isOn = model.kind == k
        Button {
            model.kind = k
        } label: {
            Text(label)
                .font(scale.captionFont)
                .padding(.horizontal, scale.space[2])
                .padding(.vertical, scale.space[1])
                .foregroundColor(isOn ? theme.color("fg") : theme.color("fg-faint"))
                .background(
                    RoundedRectangle(cornerRadius: scale.radius.small, style: .continuous)
                        .fill(isOn ? theme.color("bg-3") : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}
