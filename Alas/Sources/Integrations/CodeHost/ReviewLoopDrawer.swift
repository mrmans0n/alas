import SwiftUI

enum ReviewLoopDrawerModel {
    static func identityText(request: ReviewRequest?, remoteKind: CodeHostKind?) -> String {
        if let request { return request.displayIdentity }
        return remoteKind?.displayName ?? "Review loop"
    }

    static func headerText(request: ReviewRequest?, remoteKind: CodeHostKind?) -> String {
        identityText(request: request, remoteKind: remoteKind).uppercased()
    }

    static func statusText(request _: ReviewRequest?, action: ReviewLoopAction) -> String {
        switch action.kind {
        case .prepareCheckFailureHandoff:
            "CI failed"
        case .prepareReviewHandoff:
            "Review feedback"
        case .waitForChecks:
            "Checks running"
        case .waitForReview:
            "Review pending"
        case .readyToMerge:
            "Ready"
        case .pushBranch:
            "Needs push"
        case .createReviewRequest:
            "No PR"
        case .installProviderCLI:
            "Missing CLI"
        case .authenticateProvider:
            "Auth needed"
        case .rerunFailedChecks:
            "Rerun checks"
        case .blocked:
            "Blocked"
        default:
            action.title
        }
    }

    static func primaryButtonTitle(for kind: ReviewLoopActionKind) -> String {
        switch kind {
        case .startSession:
            "Start"
        case .prepareCheckFailureHandoff, .prepareReviewHandoff:
            "Open in agent"
        case .installProviderCLI:
            "How to install"
        case .authenticateProvider:
            "How to auth"
        case .readyToMerge:
            "Merge"
        case .rerunFailedChecks:
            "Rerun"
        default:
            "Run"
        }
    }

    static func isPrimaryActionEnabled(
        _ kind: ReviewLoopActionKind,
        canOpenAgentHandoff: Bool = true
    ) -> Bool {
        switch kind {
        case .startSession, .pushBranch, .createReviewRequest, .rerunFailedChecks:
            true
        case .prepareCheckFailureHandoff, .prepareReviewHandoff:
            canOpenAgentHandoff
        default:
            false
        }
    }

    static func detailText(action: ReviewLoopAction, lastError: String?) -> String {
        if let lastError, !lastError.isEmpty {
            return lastError
        }
        return action.detail
    }
}

struct ReviewLoopDrawer: View {
    @Bindable var state: ReviewLoopState
    let action: ReviewLoopAction
    let onPrimaryAction: () -> Void
    let onOpenProvider: () -> Void
    let onRefresh: () -> Void
    let canOpenAgentHandoff: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        let request = state.snapshot?.reviewRequest
        let remoteKind = state.snapshot?.remote?.kind
        VStack(spacing: 0) {
            Divider().opacity(0.45)
            Button {
                state.setExpanded(!state.isExpanded)
            } label: {
                collapsedRow(request: request, remoteKind: remoteKind)
            }
            .buttonStyle(.plain)

            if state.isExpanded {
                expandedBody(request: request)
            }
        }
        .background(theme.color("bg-1").opacity(0.96))
    }

    private func collapsedRow(request: ReviewRequest?, remoteKind: CodeHostKind?) -> some View {
        HStack(spacing: 7) {
            NerdFontGlyphView(symbol: "\u{EA84}", hex: "7A8089")
                .frame(width: 13, height: 13)
            Text(ReviewLoopDrawerModel.headerText(request: request, remoteKind: remoteKind))
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.middle)

            if state.isRefreshing {
                Spinner(lineWidth: 1.4, duration: 0.8)
                    .frame(width: 11, height: 11)
            }

            Spacer(minLength: 6)

            Text(ReviewLoopDrawerModel.statusText(request: request, action: action))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(1)
                .truncationMode(.tail)
            Icon(name: state.isExpanded ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func expandedBody(request: ReviewRequest?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(action.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.color("fg"))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(ReviewLoopDrawerModel.detailText(
                action: action,
                lastError: state.lastError
            ))
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                AlasButton(
                    title: ReviewLoopDrawerModel.primaryButtonTitle(for: action.kind),
                    style: .normal,
                    action: onPrimaryAction
                )
                .disabled(!ReviewLoopDrawerModel.isPrimaryActionEnabled(
                    action.kind,
                    canOpenAgentHandoff: canOpenAgentHandoff
                ))

                Menu {
                    Button("Refresh", action: onRefresh)
                    Button("Open in Browser", action: onOpenProvider)
                        .disabled(request == nil)
                } label: {
                    Icon(name: "menu", size: 11, color: theme.color("fg-faint"))
                        .frame(width: 24, height: 24)
                        .background(theme.color("bg-3"))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if let request {
                requestFacts(request)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func requestFacts(_ request: ReviewRequest) -> some View {
        VStack(spacing: 4) {
            fact("Branch", request.headRefName)
            fact("Checks", request.worstCheckBucket?.rawValue ?? "none")
            fact("Reviews", request.reviewDecision.rawValue)
            fact("Merge", request.mergeState.rawValue)
        }
        .font(.system(size: 10.5))
        .foregroundColor(theme.color("fg-dim"))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            Text(value)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
