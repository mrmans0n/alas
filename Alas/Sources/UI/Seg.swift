import SwiftUI

struct Seg<Value: Hashable>: View {
    enum Content {
        case text(String)
        case systemImage(String)
    }

    @Binding var value: Value
    let options: [(Value, Content)]
    @Environment(\.theme) var theme

    init(value: Binding<Value>, options: [(Value, String)]) {
        self._value = value
        self.options = options.map { ($0.0, .text($0.1)) }
    }

    init(value: Binding<Value>, systemImageOptions: [(Value, String)]) {
        self._value = value
        self.options = systemImageOptions.map { ($0.0, .systemImage($0.1)) }
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.0) { item in
                Button {
                    value = item.0
                } label: {
                    label(for: item.1)
                        .font(.system(size: 12))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(value == item.0 ? theme.color("bg-3") : .clear)
                        .foregroundColor(value == item.0 ? theme.color("fg") : theme.color("fg-muted"))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.color("bg-0"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func label(for content: Content) -> some View {
        switch content {
        case .text(let s): Text(s)
        case .systemImage(let name): Image(systemName: name)
        }
    }
}
