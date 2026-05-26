import SwiftUI

struct EditorLSPStatusOverridePicker: View {
    let availableLanguages: [(language: String, displayName: String)]
    let onPick: (String) -> Void
    let onOpenSettings: () -> Void
    @State private var query: String = ""
    @Environment(\.theme) var theme

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
                .font(.system(size: 11))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered, id: \.language) { entry in
                        Button {
                            onPick(entry.language)
                        } label: {
                            HStack {
                                Text(entry.displayName)
                                    .font(.system(size: 11))
                                Spacer()
                                Text(entry.language)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(theme.color("fg-muted"))
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
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
                .font(.system(size: 11))
        }
        .padding(8)
        .frame(width: 260)
    }
}
