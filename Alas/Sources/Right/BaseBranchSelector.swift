import SwiftUI

struct BaseBranchSelector: View {
    @Binding var baseBranch: String
    let branches: [String]
    let currentRef: String?
    let onSelect: (String) -> Void
    let onOpen: () -> Void

    @Environment(\.theme) private var theme
    @State private var open = false
    @State private var search = ""
    @State private var hovering = false

    var body: some View {
        Button(action: {
            onOpen()
            open.toggle()
        }) {
            HStack(spacing: 4) {
                Icon(name: "branch", size: 10, color: hovering ? theme.color("accent") : theme.color("fg-faint"))
                Text(currentRef ?? baseBranch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(hovering ? theme.color("accent") : theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popoverBody
        }
    }

    private var filteredBranches: [String] {
        if search.isEmpty { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlasField(text: $search, placeholder: "Search branches...")
                .padding(8)
            Divider().background(theme.color("line"))
            if branches.isEmpty {
                Text("No branches")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredBranches, id: \.self) { branch in
                            row(name: branch)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 280)
    }

    private func row(name: String) -> some View {
        Button(action: {
            onSelect(name)
            open = false
        }) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .opacity(name == baseBranch ? 1 : 0)
                Text(name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension BaseBranchSelector {
    static func smartList(
        branches: [String],
        currentRef: String?,
        upstream: String?,
        recent: [String]
    ) -> [String] {
        let mainlineNames = ["main", "master", "develop", "trunk"]
        var seen = Set<String>()
        var out: [String] = []

        func append(_ name: String) {
            guard seen.insert(name).inserted else { return }
            out.append(name)
        }

        // 1. Mainlines (local first, then every remote that carries it)
        for name in mainlineNames {
            if branches.contains(name) { append(name) }
            for branch in branches {
                if branch.hasSuffix("/\(name)") && branch.contains("/") {
                    append(branch)
                }
            }
        }

        // 2. Upstream (if not already a mainline)
        if let upstream { append(upstream) }

        // 3. Recent (max 3, newest first)
        for name in recent.reversed().prefix(3) {
            append(name)
        }

        // 4. Active comparison ref (so users can always re-select it)
        if let currentRef { append(currentRef) }

        // 5. Remaining branches, so search can reach refs outside the smart shortlist.
        for branch in branches {
            append(branch)
        }

        return out
    }
}
