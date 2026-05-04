import SwiftUI

struct ChangesSectionView: View {
    let changes: [ChangedFile]
    let onSelect: (ChangedFile) -> Void
    let onRefresh: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                ForEach(grouped, id: \.0) { (dir, files) in
                    Section {
                        ForEach(files) { file in
                            ChangedRow(file: file, onSelect: { onSelect(file) })
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text(dir.isEmpty ? "(root)" : dir)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(theme.color("fg-faint"))
                            .padding(.horizontal, 12).padding(.top, 6)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var grouped: [(String, [ChangedFile])] {
        let dict = Dictionary(grouping: changes, by: { f -> String in
            let comps = f.path.split(separator: "/")
            return comps.dropLast().joined(separator: "/")
        })
        return dict.sorted { $0.key < $1.key }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("CHANGES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
                .tracking(0.5)
            Text("\(changes.count)")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(theme.color("bg-4"))
                .clipShape(Capsule())
                .foregroundColor(theme.color("fg-muted"))
            Spacer()
            HStack(spacing: 6) {
                Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                Text("−\(totalDel)").foregroundColor(theme.color("del"))
            }
            .font(.system(size: 11, design: .monospaced))
            Button(action: onRefresh) {
                Icon(name: "search", size: 11)
            }
            .buttonStyle(.plain)
            .opacity(0.6)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var totalAdd: Int { changes.reduce(0) { $0 + $1.add } }
    private var totalDel: Int { changes.reduce(0) { $0 + $1.del } }
}

private struct ChangedRow: View {
    let file: ChangedFile
    let onSelect: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Icon(name: "file", size: 11, color: theme.color("fg-faint"))
                Text(file.path.split(separator: "/").last.map(String.init) ?? file.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if file.add > 0 { Text("+\(file.add)").foregroundColor(theme.color("add")) }
                if file.del > 0 { Text("−\(file.del)").foregroundColor(theme.color("del")) }
                StatusBadge(status: file.status)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct StatusBadge: View {
    let status: String
    @Environment(\.theme) var theme
    var body: some View {
        Text(status)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 4)
            .background(badgeBg)
            .foregroundColor(badgeFg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    private var badgeBg: Color {
        switch status {
        case "A": return theme.color("add").opacity(0.18)
        case "D": return theme.color("del").opacity(0.18)
        case "R": return theme.color("info").opacity(0.18)
        default:  return theme.color("mod").opacity(0.20)
        }
    }
    private var badgeFg: Color {
        switch status {
        case "A": return theme.color("add")
        case "D": return theme.color("del")
        case "R": return theme.color("info")
        default:  return theme.color("mod")
        }
    }
}
