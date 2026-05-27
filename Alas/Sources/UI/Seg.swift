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
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { item in
                let isActive = value == item.0
                Button {
                    value = item.0
                } label: {
                    label(for: item.1)
                        .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                        .background(
                            ZStack {
                                if isActive {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(theme.color("bg-3"))
                                    // Top inner highlight
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.white.opacity(0.04), lineWidth: 1)
                                        .blendMode(.plusLighter)
                                }
                            }
                        )
                        .foregroundColor(isActive ? theme.color("fg") : theme.color("fg-muted"))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: isActive ? Color.black.opacity(0.25) : .clear, radius: 1, x: 0, y: 1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(theme.color("seg-container-bg"))
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
