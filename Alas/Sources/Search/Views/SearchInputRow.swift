import SwiftUI

struct SearchInputRow: View {
    @Bindable var model: SearchModel
    @FocusState.Binding var inputFocused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(theme.color("fg-dim"))
            TextField(placeholderText, text: $model.query)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .font(.system(size: 15))
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
                        .font(.system(size: 9, weight: .bold))
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
            .padding(2)
            .background(theme.color("bg-2"))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundColor(isOn ? theme.color("fg") : theme.color("fg-faint"))
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(isOn ? theme.color("bg-3") : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}
