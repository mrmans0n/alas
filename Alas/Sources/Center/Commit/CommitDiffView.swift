import SwiftUI

struct CommitDiffView: View {
    let path: String
    let diff: ParsedDiff
    let loading: Bool
    let error: String?

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .background(theme.color("bg-1"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text((path as NSString).lastPathComponent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.color("fg"))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((path as NSString).deletingLastPathComponent)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView().padding()
        } else if let error {
            Text("Could not load diff for \(path): \(error)")
                .font(.system(size: 11))
                .foregroundColor(theme.color("del"))
                .padding()
        } else if diff.hunks.isEmpty {
            Text("No changes for \(path)")
                .foregroundColor(theme.color("fg-dim"))
                .padding()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { (_, hunk) in
                        HunkView(hunk: hunk, fileExtension: (path as NSString).pathExtension)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }
}
