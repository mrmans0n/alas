import SwiftUI

struct OperationCard: View {
    let operation: MergeOperation
    let hasUnresolvedConflicts: Bool
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onAbort: () -> Void

    @Environment(\.theme) private var theme

    /// System orange text and black hairlines assume a dark surface; the
    /// light theme uses its own `warn` and `line` instead.
    private var tint: Color { theme.darkMode ? .orange : theme.color("warn") }
    private var rule: Color { theme.darkMode ? .black.opacity(0.3) : theme.color("line") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            subtitle
            if case .rebase(let plan) = operation, !plan.commits.isEmpty {
                progressBar(plan: plan)
                planList(plan: plan)
            }
            actions
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.25), tint.opacity(0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(Rectangle().frame(height: 1).foregroundColor(rule), alignment: .bottom)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
        }
    }

    private var title: String {
        switch operation {
        case .merge:      return "Merging"
        case .rebase:     return "Rebasing"
        case .cherryPick: return "Cherry-picking"
        case .revert:     return "Reverting"
        }
    }

    private var subtitle: some View {
        Text(subtitleText)
            .font(.system(size: 11))
            .foregroundColor(.primary)
    }

    private var subtitleText: String {
        switch operation {
        case .merge(let src):
            if let src { return "\(src) into current branch" }
            return "into current branch"
        case .rebase(let plan):
            let position = (plan.currentIndex.map { "commit \($0 + 1) of \(plan.commits.count)" }) ?? "in progress"
            switch (plan.sourceBranch, plan.ontoBranch) {
            case let (src?, onto?): return "\(src) onto \(onto) · \(position)"
            case let (src?, nil):   return "\(src) · \(position)"
            default:                return position
            }
        case .cherryPick(let sha, let summary),
             .revert(let sha, let summary):
            return "\(String(sha.prefix(7))) · \(summary)"
        }
    }

    private func progressBar(plan: RebasePlan) -> some View {
        let done = plan.commits.filter { $0.state == .done }.count
        let current = plan.commits.contains { $0.state == .current } ? 1 : 0
        let fraction = Double(done + current) / Double(max(plan.commits.count, 1))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(rule)
                Rectangle().fill(tint).frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    private func planList(plan: RebasePlan) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(plan.commits.prefix(6), id: \.sha) { commit in
                HStack(spacing: 4) {
                    Text(symbol(commit.state))
                        .foregroundColor(color(commit.state))
                    Text(commit.summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(color(commit.state))
                }
                .font(.system(size: 10))
            }
            if plan.commits.count > 6 {
                Text("…\(plan.commits.count - 6) more")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    private func symbol(_ s: RebasePlanCommit.State) -> String {
        switch s { case .done: return "✓"
        case .current: return "▸"
        case .pending: return "·" }
    }
    private func color(_ s: RebasePlanCommit.State) -> Color {
        switch s { case .done: return .green
        case .current: return tint
        case .pending: return .secondary }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button(action: onContinue) { Text("Continue").font(.system(size: 11)) }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(hasUnresolvedConflicts)
            if case .merge = operation {} else {
                Button(action: onSkip) { Text("Skip").font(.system(size: 11)) }
                    .buttonStyle(.bordered)
            }
            Spacer()
            Button(action: onAbort) { Text("Abort").font(.system(size: 11)) }
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .padding(.top, 4)
    }
}
