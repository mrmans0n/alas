import SwiftUI

struct EditorLSPStatusOverridePicker: View {
    let availableLanguages: [(language: String, displayName: String)]
    let onPick: (String) -> Void
    let onOpenSettings: () -> Void
    @State private var query: String = ""
    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale

    private var filtered: [(language: String, displayName: String)] {
        let q = query.lowercased()
        guard !q.isEmpty else { return availableLanguages }
        return availableLanguages.filter {
            $0.language.lowercased().contains(q) ||
            $0.displayName.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Search…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(scale.meta.font)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered, id: \.language) { entry in
                        Button {
                            onPick(entry.language)
                        } label: {
                            HStack {
                                Text(entry.displayName)
                                    .font(scale.meta.font)
                                Spacer()
                                Text(entry.language)
                                    .font(scale.caption.font(weight: .regular, design: .monospaced))
                                    .foregroundColor(theme.color("fg-muted"))
                            }
                            .padding(.horizontal, scale.space[2])
                            .padding(.vertical, scale.space[1])
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 180)
            Divider()
            Button("Configure more servers in Settings…", action: onOpenSettings)
                .buttonStyle(.link)
                .font(scale.meta.font)
        }
        .padding(scale.space[2])
        .frame(width: 260)
    }
}
