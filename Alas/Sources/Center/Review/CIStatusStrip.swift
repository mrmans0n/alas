import SwiftUI

struct CIStatusStrip: View {
    let checks: [ReviewCheck]
    @State private var isExpanded = false

    @Environment(\.theme) private var theme

    private var passed: Int { checks.filter { $0.bucket == .pass }.count }
    private var failed: Int { checks.filter { $0.bucket == .fail }.count }
    private var running: Int { checks.filter { $0.bucket == .pending }.count }
    private var cancelled: Int { checks.filter { $0.bucket == .cancel }.count }
    private var skipped: Int { checks.filter { $0.bucket == .skipping }.count }

    private var summaryColor: Color {
        if failed > 0 { return theme.color("del") }
        if running > 0 { return theme.color("warn") }
        if passed > 0 { return theme.color("add") }
        return theme.color("fg-dim")
    }

    private var summaryText: String {
        if checks.isEmpty { return "No CI checks" }
        var parts: [String] = []
        if failed > 0 { parts.append("\(failed) failed") }
        if running > 0 { parts.append("\(running) running") }
        if passed > 0 { parts.append("\(passed) passed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if checks.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(theme.color("fg-dim"))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: isExpanded)
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 11))
                            .foregroundColor(summaryColor)
                        Text("CI · \(summaryText)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(summaryColor)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Divider().overlay(theme.color("line"))
                    VStack(spacing: 0) {
                        ForEach(checks) { check in
                            CICheckRow(check: check)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .background(theme.color("bg-2"))
            .overlay(alignment: .bottom) {
                Divider().overlay(theme.color("line"))
            }
        }
    }
}

private struct CICheckRow: View {
    let check: ReviewCheck
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 11))
                .foregroundColor(statusColor)
                .frame(width: 14)
            Text(check.name)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
            if let workflow = check.workflow {
                Text(workflow)
                    .font(.system(size: 10))
                    .foregroundColor(theme.color("fg-dim"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let url = check.detailURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-dim"))
                }
                .buttonStyle(.plain)
                .help("Open in browser")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 5)
    }

    private var statusIcon: String {
        switch check.bucket {
        case .pass:     return "checkmark.circle.fill"
        case .fail:     return "xmark.circle.fill"
        case .pending:  return "clock.fill"
        case .cancel:   return "minus.circle.fill"
        case .skipping: return "forward.fill"
        case .unknown:  return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch check.bucket {
        case .pass:     return theme.color("add")
        case .fail:     return theme.color("del")
        case .pending:  return theme.color("warn")
        case .cancel:   return theme.color("fg-dim")
        case .skipping: return theme.color("fg-dim")
        case .unknown:  return theme.color("fg-faint")
        }
    }
}
