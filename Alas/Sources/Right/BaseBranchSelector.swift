import SwiftUI

struct BaseBranchSelector: View {
    @Binding var baseBranch: String
    let branches: [String]
    let currentRef: String?
    let onSelect: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var open = false
    @State private var search = ""

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 4) {
                Icon(name: "branch", size: 10, color: theme.color("fg-faint"))
                Text(currentRef ?? baseBranch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            // Placeholder for popover body (Task 3)
            EmptyView()
        }
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

        // 1. Mainlines (local first, then its remote, in priority order)
        for name in mainlineNames {
            if branches.contains(name) { append(name) }
            let remote = "origin/\(name)"
            if branches.contains(remote) { append(remote) }
        }

        // 2. Upstream (if not already a mainline)
        if let upstream { append(upstream) }

        // 3. Recent (max 3, newest first)
        for name in recent.prefix(3) {
            append(name)
        }

        return out
    }
}
