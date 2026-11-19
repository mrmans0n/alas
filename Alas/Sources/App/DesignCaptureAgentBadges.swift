#if DEBUG
import AlasCore
import SwiftUI

/// Design-capture target for the sidebar's agent badge hover card. The real card
/// opens on hover over a live session, which a capture cannot script, so this
/// draws `AgentBadgePopover` for scripted models next to a few badge strips as
/// worktree rows show them. Nothing is read from sessions or the harness.
/// Debug builds only, and only on a capture profile.
///
/// - agent-badge-popovers: running with a plan, waiting on a permission,
///   awaiting input, idle with a reply, a terminal session, a bare model; and
///   badge strips (active and idle, all idle with "+1").
@MainActor
enum DesignCaptureAgentBadges {
    static let targets: Set<String> = ["agent-badge-popovers"]

    static func open(_ target: String, state: AppState) {
        guard DesignCaptureWorkspace.isCaptureInstance, targets.contains(target) else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(30)
            while state.projects.isEmpty {
                guard Date() < deadline else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            let gallery = Gallery()
                .environment(\.theme, state.themeStore.current)
                .environment(\.designScale, .resolved(for: state.config.density))
            DesignCaptureWorkspace.present(gallery)
        }
    }

    private static let now = Date(timeIntervalSince1970: 1_795_000_000)

    private static func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private static let models: [(label: String, model: AgentBadgePopoverModel)] = [
        ("running, plan", AgentBadgePopoverModel(
            agentName: AgentKind.claude.displayName, agentLogoAsset: AgentKind.claude.logoAssetName,
            title: "Move invoice export to the background queue", status: .running, since: ago(120),
            body: .plan(completed: 2, total: 5, step: "Run the export tests"),
            model: "Opus 5.5", contextPercent: 63
        )),
        ("permission", AgentBadgePopoverModel(
            agentName: AgentKind.codex.displayName, agentLogoAsset: AgentKind.codex.logoAssetName,
            title: "Fix flaky checkpoint restore test", status: .permission, since: ago(300),
            body: .request("swift test --package-path Packages/AlasCore"),
            model: "GPT-5.5", contextPercent: 41
        )),
        ("awaiting input", AgentBadgePopoverModel(
            agentName: AgentKind.claude.displayName, agentLogoAsset: AgentKind.claude.logoAssetName,
            title: "Rename the billing settings pane", status: .awaitingInput, since: ago(540),
            body: .excerpt("Should the old \"Payments\" key stay as an alias so existing preferences keep working, or can I drop it?"),
            model: "Sonnet 5", contextPercent: 18
        )),
        ("idle, reply", AgentBadgePopoverModel(
            agentName: AgentKind.codex.displayName, agentLogoAsset: AgentKind.codex.logoAssetName,
            title: "Audit retry paths in the sync client", status: .idle, since: ago(3_900),
            body: .excerpt("Done. The sync client retried uploads on every 4xx, including 401 and 403, which turned an expired token into a storm of requests. Retries now stop on client errors and back off on 429 and 5xx; I added tests for each status class and updated the docs."),
            model: "GPT-5.5", contextPercent: 72
        )),
        ("terminal", AgentBadgePopoverModel(
            agentName: AgentKind.claude.displayName, agentLogoAsset: AgentKind.claude.logoAssetName,
            title: "zsh — lantern", status: .awaitingInput, since: ago(60),
            body: .excerpt("Claude is waiting for your input")
        )),
        ("minimal", AgentBadgePopoverModel(
            agentName: AgentKind.gemini.displayName, agentLogoAsset: AgentKind.gemini.logoAssetName,
            title: "New session", status: .idle, since: nil, body: .none
        )),
    ]

    private static func badge(_ id: String, _ agent: AgentKind, _ state: HarnessService.AggregatedState?) -> HarnessService.WorktreeBadgeSession {
        HarnessService.WorktreeBadgeSession(id: id, agent: agent, state: state, updatedAt: nil)
    }

    private static let strips: [(label: String, badges: [HarnessService.WorktreeBadgeSession])] = [
        ("active + idle", [badge("a1", .claude, .running), badge("a2", .codex, nil)]),
        ("waiting + idle", [badge("b1", .codex, .awaiting), badge("b2", .claude, nil), badge("b3", .gemini, nil)]),
        ("all idle, +1", [badge("c1", .claude, nil), badge("c2", .codex, nil), badge("c3", .gemini, nil), badge("c4", .cursor, nil)]),
    ]

    private struct Gallery: View {
        @Environment(\.theme) private var theme

        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                // Eager rows: the panel is sized once from the fitting size.
                Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 14) {
                    ForEach(Array(stride(from: 0, to: DesignCaptureAgentBadges.models.count, by: 2)), id: \.self) { start in
                        GridRow {
                            ForEach(start..<min(start + 2, DesignCaptureAgentBadges.models.count), id: \.self) { index in
                                let entry = DesignCaptureAgentBadges.models[index]
                                labelled(entry.label) {
                                    AgentBadgePopover(model: entry.model, now: DesignCaptureAgentBadges.now)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(DesignCaptureAgentBadges.strips.indices, id: \.self) { index in
                        let strip = DesignCaptureAgentBadges.strips[index]
                        labelled(strip.label) { badgeStrip(strip.badges) }
                    }
                }
                .frame(width: 140, alignment: .leading)
            }
            .padding(14)
            .background(theme.color("bg-0"))
        }

        private func labelled(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                content()
            }
        }

        /// As `WorktreeRowView.agentBadges` lays them out.
        private func badgeStrip(_ badges: [HarnessService.WorktreeBadgeSession]) -> some View {
            let visible = WorktreeRowView.visibleHarnessSessionCount(for: badges.count)
            return HStack(spacing: 4) {
                ForEach(badges.prefix(visible)) { session in
                    HarnessSessionBadge(session: session, onActivate: {})
                }
                if badges.count > visible {
                    HarnessSessionOverflowBadge(sessions: Array(badges.dropFirst(visible)), onActivate: { _ in })
                }
            }
            .padding(8)
            .background(theme.color("bg-1"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
#endif
