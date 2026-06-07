import SwiftUI

enum SettingsRowLayout {
    static let columnSpacing: CGFloat = 16
    static let dropdownControlWidth: CGFloat = 240

    static func columnWidth(for rowWidth: CGFloat) -> CGFloat {
        max(0, (rowWidth - columnSpacing) / 2)
    }
}

struct SettingsRow<Control: View>: View {
    let name: String
    var desc: String? = nil
    @ViewBuilder let control: () -> Control
    @Environment(\.theme) var theme

    var body: some View {
        HStack(alignment: .top, spacing: SettingsRowLayout.columnSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                if let desc {
                    Text(desc).font(.system(size: 11.5))
                        .foregroundColor(theme.color("fg-dim"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                control()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .overlay(Divider().opacity(0.5), alignment: .top)
    }
}

extension View {
    func settingsDropdownFrame() -> some View {
        frame(width: SettingsRowLayout.dropdownControlWidth, alignment: .leading)
    }
}
