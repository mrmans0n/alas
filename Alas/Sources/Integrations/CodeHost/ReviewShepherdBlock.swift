import SwiftUI

/// What the Changes review drawer shows about the PR shepherd. Built by
/// `ChangesTabView` from `AppState` so the drawer itself does no app lookups.
struct ReviewShepherdDrawerModel {
    struct Candidate: Identifiable, Equatable {
        let id: String
        let title: String
        let agentName: String?

        var menuTitle: String {
            agentName.map { "\(title) · \($0)" } ?? title
        }
    }

    /// Nil when the open PR is not shepherded yet.
    let record: ShepherdRecord?
    let presentation: ShepherdPresentation
    /// Nil when the owning session is archived or no longer exists.
    let ownerTitle: String?
    let ownerAgent: AgentDefinition?
    /// Sessions that can take the PR, newest `updatedAt` first, excluding the owner.
    let candidates: [Candidate]
    let setAutoFix: @MainActor (Bool) -> Void
    let setAutoMerge: @MainActor (Bool) -> Void
    let jump: @MainActor () -> Void
    let stop: @MainActor () -> Void
    let resume: @MainActor () -> Void
    let shepherdWith: @MainActor (_ sessionID: String) -> Void
    let shepherdWithNewSession: @MainActor () -> Void
    /// Reloads the worktree's recent sessions so the menus offer current ones.
    let refreshSessions: @MainActor () -> Void
}

/// Shepherd section inside the expanded review drawer, above the actions.
struct ReviewShepherdBlock: View {
    let model: ReviewShepherdDrawerModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let record = model.record {
                bound(record)
            } else {
                unbound
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.color("bg-2").opacity(0.48))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PR shepherd")
        .onAppear { model.refreshSessions() }
    }

    /// The owner and Jump live in `ReviewShepherdBanner` above the drawer.
    @ViewBuilder
    private func bound(_ record: ShepherdRecord) -> some View {
        Text(model.presentation.phaseLine)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-dim"))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        toggle(
            "Auto-fix CI, conflicts and reviews",
            isOn: record.autoFix,
            isDisabled: record.phase.isTerminal,
            set: model.setAutoFix
        )
        toggle(
            "Auto-merge when ready (squash)",
            isOn: record.autoMerge,
            isDisabled: record.phase.isTerminal,
            set: model.setAutoMerge
        )

        HStack(spacing: 8) {
            if record.phase.isResumable {
                ReviewShepherdActionButton(title: "Resume", systemImage: "play", help: "Watch again and reset the fix attempt count") {
                    model.resume()
                }
            }
            ReviewShepherdActionButton(title: "Stop shepherding", systemImage: "stop", help: "Stop watching. The PR stays open.") {
                model.stop()
            }
            Spacer(minLength: 0)
            if !record.phase.isTerminal {
                ReviewShepherdSessionMenu(model: model, title: "Move to…", help: "Hand this PR to another session")
            }
        }
    }

    private var unbound: some View {
        HStack(spacing: 6) {
            Image(systemName: "pawprint")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(theme.color("fg-faint"))
            Text("Not shepherded")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            Spacer(minLength: 6)
            ReviewShepherdSessionMenu(model: model, title: "Shepherd with…", help: "Have a session fix and merge this PR")
        }
    }

    private func toggle(
        _ title: String,
        isOn: Bool,
        isDisabled: Bool,
        set: @escaping @MainActor (Bool) -> Void
    ) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { set($0) })) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.color("fg"))
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(isDisabled)
        .help(title)
    }
}

/// Sessions sorted by `updatedAt` (the history list sorts by
/// `lastOpenedAt`, so the order here is explicit), then "New session".
struct ReviewShepherdSessionMenu: View {
    let model: ReviewShepherdDrawerModel
    let title: String
    let help: String

    var body: some View {
        Menu {
            ForEach(model.candidates) { candidate in
                Button(candidate.menuTitle) {
                    model.shepherdWith(candidate.id)
                }
            }
            if !model.candidates.isEmpty {
                Divider()
            }
            Button("New session") {
                model.shepherdWithNewSession()
            }
        } label: {
            Label(title, systemImage: "pawprint")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help(help)
        .accessibilityLabel(title)
    }
}

struct ReviewShepherdActionButton: View {
    let title: String
    let systemImage: String
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(theme.color("fg-muted"))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(theme.color("bg-3").opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
        .accessibilityLabel(title)
    }
}

/// Full-width strip above the review drawer naming the session that
/// shepherds the drawer's PR, with Jump. Shown only while a record exists.
struct ReviewShepherdBanner: View {
    let model: ReviewShepherdDrawerModel
    @Environment(\.theme) private var theme

    var body: some View {
        let accent = theme.color("accent")
        HStack(spacing: 7) {
            if let ownerTitle = model.ownerTitle {
                if let agent = model.ownerAgent {
                    AgentLogoView(agent: agent, size: 14)
                }
                Text(ownerLine(ownerTitle))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                ReviewShepherdActionButton(
                    title: "Jump",
                    systemImage: "arrow.up.forward.square",
                    help: "Focus the session that owns this PR",
                    action: { model.jump() }
                )
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(theme.color("warn"))
                Text("Owner session archived or missing")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.color("warn"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if model.record?.phase.isTerminal == false {
                    ReviewShepherdSessionMenu(model: model, title: "Shepherd with…", help: "Have a session fix and merge this PR")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(accent.opacity(0.35))
                .frame(height: 0.5)
        }
        .aiBeam(isActive: model.presentation.badge.isActive, cornerRadius: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PR shepherd")
        .accessibilityValue(model.presentation.tooltip)
        .help(model.presentation.tooltip)
        .onAppear { model.refreshSessions() }
    }

    private func ownerLine(_ ownerTitle: String) -> String {
        let owner = [model.ownerAgent?.displayName, ownerTitle].compactMap { $0 }.joined(separator: " · ")
        let number = model.presentation.number.map { " \($0)" } ?? ""
        return "\(owner) is shepherding\(number) · \(model.presentation.phaseLine)"
    }
}
