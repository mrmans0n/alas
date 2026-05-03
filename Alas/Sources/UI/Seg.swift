import SwiftUI

struct Seg<Value: Hashable>: View {
    @Binding var value: Value
    let options: [(Value, String)]
    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.0) { item in
                Button {
                    value = item.0
                } label: {
                    Text(item.1)
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
}
