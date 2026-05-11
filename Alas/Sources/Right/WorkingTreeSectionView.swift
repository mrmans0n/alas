import SwiftUI

struct WorkingTreeSectionView: View {
    let changes: [ChangedFile]
    @Binding var expanded: Bool
    let onSelect: (ChangedFile) -> Void

    @Environment(\.theme) private var theme

    @State private var stagedExpanded: Bool = true
    @State private var unstagedExpanded: Bool = true

    private var staged:   [ChangedFile] { changes.filter { $0.stage == .staged   } }
    private var unstaged: [ChangedFile] { changes.filter { $0.stage == .unstaged } }
    private var totalAdd: Int { changes.reduce(0) { $0 + $1.add } }
    private var totalDel: Int { changes.reduce(0) { $0 + $1.del } }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(
                title: "Working tree",
                count: changes.count,
                expanded: expanded,
                onToggle: { expanded.toggle() }
            ) {
                if shouldShowChangeSummary(additions: totalAdd, deletions: totalDel) {
                    HStack(spacing: 6) {
                        Text("+\(totalAdd)").foregroundColor(theme.color("add"))
                        Text("−\(totalDel)").foregroundColor(theme.color("del"))
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }

            if expanded {
                if changes.isEmpty {
                    Text("no changes")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("fg-faint"))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if !staged.isEmpty {
                        subsection(title: "Staged", files: staged, expanded: $stagedExpanded)
                    }
                    if !unstaged.isEmpty {
                        subsection(title: "Unstaged", files: unstaged, expanded: $unstagedExpanded)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func subsection(title: String, files: [ChangedFile], expanded: Binding<Bool>) -> some View {
        SubHeader(
            title: title,
            count: files.count,
            expanded: expanded.wrappedValue,
            onToggle: { expanded.wrappedValue.toggle() }
        )
        if expanded.wrappedValue {
            ForEach(directoryGroups(files), id: \.0) { (dir, items) in
                if !dir.isEmpty || shouldShowRootHeader(in: files) {
                    DirectoryRowLabel(title: dir.isEmpty ? "(root)" : dir)
                }
                ForEach(items) { file in
                    ChangedRow(file: file, onSelect: { onSelect(file) })
                }
            }
        }
    }

    /// Show "(root)" only when at least one file is in a subdirectory —
    /// otherwise the lone label is noisy.
    private func shouldShowRootHeader(in files: [ChangedFile]) -> Bool {
        files.contains(where: { $0.path.contains("/") })
    }

    private func directoryGroups(_ files: [ChangedFile]) -> [(String, [ChangedFile])] {
        let dict = Dictionary(grouping: files) { f -> String in
            let comps = f.path.split(separator: "/")
            return comps.dropLast().joined(separator: "/")
        }
        return dict.sorted { $0.key < $1.key }
    }
}

private struct DirectoryRowLabel: View {
    let title: String
    @Environment(\.theme) private var theme
    var body: some View {
        Text(title)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(theme.color("fg-faint"))
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
