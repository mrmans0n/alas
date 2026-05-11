import SwiftUI

struct CommitHeaderView: View {
    let details: CommitDetails
    @Binding var expanded: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            compactRow
            if expanded { expandedBlock }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            if let tag = details.info.conventionalTag {
                Text(tag)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.color("accent"))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.color("accent").opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(details.info.subject)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
            Text(details.info.shortSha)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-faint"))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text(details.info.author)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text(relativeTime(details.info.date))
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .buttonStyle(.plain)
        }
    }

    private var expandedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !details.body.isEmpty {
                Text(details.body)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text("\(details.info.author) <\(details.authorEmail)>")
                Text(absoluteDate(details.info.date))
                if !details.parents.isEmpty {
                    Text("parent" + (details.parents.count > 1 ? "s" : "") + ": " + details.parents.joined(separator: " "))
                }
                Text("\(details.files.count) file\(details.files.count == 1 ? "" : "s")")
                Text("+\(details.info.insertions)").foregroundColor(theme.color("add"))
                Text("−\(details.info.deletions)").foregroundColor(theme.color("del"))
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(theme.color("fg-faint"))
        }
        .padding(.top, 8)
    }

    private func absoluteDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}
