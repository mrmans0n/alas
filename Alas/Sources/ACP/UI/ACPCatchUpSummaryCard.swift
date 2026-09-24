import SwiftUI

enum ACPCatchUpPresentationState {
    case hidden
    case generating(snapshot: ACPCatchUpSourceSnapshot, generationID: UUID)
    case ready(snapshot: ACPCatchUpSourceSnapshot, summary: ACPCatchUpSummary)
    case sourceChanged
    case unavailable(String)
    case failed(String)
}

extension ACPCatchUpPresentationState {
    var isHidden: Bool {
        if case .hidden = self { return true }
        return false
    }

    func isStale(currentFingerprint: String?) -> Bool {
        guard case .ready(let snapshot, _) = self else { return false }
        return currentFingerprint != snapshot.fingerprint
    }
}

struct ACPCatchUpSummaryCard: View {
    let state: ACPCatchUpPresentationState
    let currentFingerprint: String?
    let sessionStatus: String
    let onRefresh: () -> Void
    let onDismiss: () -> Void
    let onOpenSource: (String) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("accent"))
                    .accessibilityHidden(true)
                Text("Session catch-up")
                    .font(.system(size: 12, weight: .semibold))
                if let provenanceText {
                    Text(provenanceText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color("fg-dim"))
                }
                Spacer(minLength: 8)
                if showsRefresh {
                    Button("Refresh", action: onRefresh)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.color("accent"))
                        .accessibilityLabel("Refresh session catch-up")
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.color("fg-muted"))
                .accessibilityLabel("Dismiss session catch-up")
            }

            content
        }
        .padding(12)
        .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session catch-up")
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .generating(let snapshot, _):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Summarizing \(scopeText(snapshot.scope).lowercased())...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("fg-muted"))
            }
            facts(snapshot: snapshot)
        case .ready(let snapshot, let summary):
            if state.isStale(currentFingerprint: currentFingerprint) {
                notice("The conversation changed after this catch-up was generated.", color: "warn")
            }
            facts(snapshot: snapshot)
            claims(title: "What changed", claims: summary.changed, snapshot: snapshot)
            claims(title: "What remains", claims: summary.remains, snapshot: snapshot)
        case .sourceChanged:
            notice("The conversation changed while the catch-up was being generated. Refresh to try again.", color: "warn")
        case .unavailable(let message), .failed(let message):
            notice(message, color: "fg-muted")
        }
    }

    private var showsRefresh: Bool {
        switch state {
        case .generating, .hidden: false
        case .ready, .sourceChanged, .unavailable, .failed: true
        }
    }

    private var provenanceText: String? {
        switch state {
        case .generating: "Generating on this Mac"
        case .ready: "Generated on this Mac"
        case .hidden, .sourceChanged, .unavailable, .failed: nil
        }
    }

    private func scopeText(_ scope: ACPCatchUpSourceSnapshot.Scope) -> String {
        switch scope {
        case .fullSession: "Full session"
        case .recentActivity(let omittedEntryCount): "Recent activity, \(omittedEntryCount) earlier items omitted"
        }
    }

    private func facts(snapshot: ACPCatchUpSourceSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                factPills(snapshot: snapshot)
            }
            VStack(alignment: .leading, spacing: 4) {
                factPills(snapshot: snapshot)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func factPills(snapshot: ACPCatchUpSourceSnapshot) -> some View {
        factPill(scopeText(snapshot.scope))
        factPill(sessionStatus)
        let evidence = snapshot.resultEvidence
        if evidence.completedCount + evidence.failedCount + evidence.cancelledCount > 0 {
            factPill(resultEvidenceText(evidence))
        }
    }

    private func factPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, 6)
            .frame(height: 19)
            .background(theme.color("bg-3"), in: Capsule())
    }

    private func resultEvidenceText(_ evidence: ACPCatchUpSourceSnapshot.ResultEvidence) -> String {
        var parts: [String] = []
        if evidence.completedCount > 0 { parts.append("\(evidence.completedCount) completed") }
        if evidence.failedCount > 0 { parts.append("\(evidence.failedCount) failed") }
        if evidence.cancelledCount > 0 { parts.append("\(evidence.cancelledCount) cancelled") }
        return "Tool results: " + parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func claims(
        title: String,
        claims: [ACPCatchUpSummary.Claim],
        snapshot: ACPCatchUpSourceSnapshot
    ) -> some View {
        if !claims.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
                ForEach(claims) { claim in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(claim.text)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.color("fg"))
                            .textSelection(.enabled)
                        Spacer(minLength: 6)
                        sourceLinks(claim.sourceStableIDs, snapshot: snapshot)
                    }
                }
            }
        }
    }

    private func sourceLinks(
        _ stableIDs: [String],
        snapshot: ACPCatchUpSourceSnapshot
    ) -> some View {
        HStack(spacing: 3) {
            ForEach(stableIDs, id: \.self) { stableID in
                if let reference = snapshot.entries.first(where: { $0.stableID == stableID })?.reference {
                    Button("[\(reference)]") { onOpenSource(stableID) }
                        .buttonStyle(.plain)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.color("accent"))
                        .accessibilityLabel("Open source message \(reference)")
                }
            }
        }
    }

    private func notice(_ text: String, color: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(theme.color(color))
    }
}
