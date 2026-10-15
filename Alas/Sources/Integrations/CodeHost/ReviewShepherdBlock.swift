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

    /// The owner and Jump live in `ReviewShepherdChip` in the collapsed row.
    @ViewBuilder
    private func bound(_ record: ShepherdRecord) -> some View {
        Text(model.presentation.phaseLine)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-dim"))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        ShepherdSwitchRow(
            title: "Auto-fix",
            detail: "CI failures, conflicts and reviewer threads go back to the shepherding session",
            isOn: record.autoFix,
            isDisabled: record.phase.isTerminal,
            set: model.setAutoFix
        )
        ShepherdSwitchRow(
            title: "Auto-merge",
            detail: "Squash-merge once checks, reviewers and the head are settled",
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
}

/// An auto-fix or auto-merge row, shared by the toolbar popover and the
/// Changes drawer: title over a one-line description, switch trailing.
struct ShepherdSwitchRow: View {
    let title: String
    let detail: String
    let isOn: Bool
    let isDisabled: Bool
    let set: @MainActor (Bool) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.color("fg"))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.color("fg-muted"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(isDisabled ? 0.5 : 1)
            Spacer(minLength: 0)
            Toggle(title, isOn: Binding(get: { isOn }, set: { set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isDisabled)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .help(detail)
    }
}

/// The pick in the Changes tab's "Shepherd with" line. Tab state stores nil
/// until the user picks, which means the newest candidate.
enum ChangesShepherdChoice: Codable, Equatable {
    case noSession
    case session(String)

    /// The session to bind a created request to, given the candidates newest
    /// first. A picked session that is no longer offered falls back to the
    /// newest; with no candidates there is nothing to bind.
    static func sessionID(for choice: ChangesShepherdChoice?, candidateIDs: [String]) -> String? {
        switch choice {
        case .noSession:
            return nil
        case .session(let id) where candidateIDs.contains(id):
            return id
        case .session, nil:
            return candidateIDs.first
        }
    }
}

/// "Shepherd with [session ▾]" in the Draft PR and Draft commit tabs: the
/// request the tab creates is bound to the picked session, which then fixes
/// and merges it like a PR it opened itself. The tabs reload the sessions.
struct ChangesShepherdLine: View {
    /// Newest `updatedAt` first; the line is not shown without any.
    let candidates: [ReviewShepherdDrawerModel.Candidate]
    let selectedID: String?
    let reviewRequestLabel: String
    let isDisabled: Bool
    let select: (ChangesShepherdChoice) -> Void
    @Environment(\.theme) private var theme

    private var selected: ReviewShepherdDrawerModel.Candidate? {
        candidates.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(
                get: { selectedID != nil },
                set: { on in select(on ? candidates.first.map { .session($0.id) } ?? .noSession : .noSession) }
            )) {
                Text("Shepherd with")
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Shepherd the \(reviewRequestLabel) after creating it")
            Menu {
                ForEach(candidates) { candidate in
                    Button(candidate.menuTitle) { select(.session(candidate.id)) }
                }
                Divider()
                Button("None") { select(.noSession) }
            } label: {
                Text(selected?.menuTitle ?? "None")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .accessibilityLabel("Shepherding session")
            .accessibilityValue(selected?.menuTitle ?? "None")
            Spacer(minLength: 0)
        }
        .disabled(isDisabled)
        .help("Once the \(reviewRequestLabel) is created, this session fixes CI failures, conflicts and reviewer threads, and can merge it")
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


/// The shepherd's chip in the review drawer's collapsed row, styled like the
/// status chips beside it. Names the owning session and jumps to it; while the
/// shepherd acts on the PR it shows the phase instead and runs the AI beam.
/// Shown only while a record exists.
struct ReviewShepherdChip: View {
    let model: ReviewShepherdDrawerModel
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let ownerTitle = model.ownerTitle {
                Button(action: model.jump) {
                    chip(title: label(ownerTitle), color: theme.color("fg-faint"), textColor: theme.color("fg-dim")) {
                        if let agent = model.ownerAgent {
                            AgentLogoView(agent: agent, size: 11)
                        } else {
                            Image(systemName: "pawprint")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("\(ownerLine(ownerTitle)). Click to focus the session.")
                .accessibilityLabel("PR shepherd \(ownerTitle)")
                .accessibilityHint("Focus the session that owns this PR")
            } else {
                Menu {
                    if model.record?.phase.isTerminal == false {
                        ForEach(model.candidates) { candidate in
                            Button(candidate.menuTitle) { model.shepherdWith(candidate.id) }
                        }
                        if !model.candidates.isEmpty {
                            Divider()
                        }
                        Button("New session") { model.shepherdWithNewSession() }
                    }
                } label: {
                    chip(title: "Owner missing", color: theme.color("warn"), textColor: theme.color("warn")) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(model.record?.phase.isTerminal != false)
                .help("The session shepherding \(model.presentation.number ?? "this PR") was archived or no longer exists. Click to hand it to another session.")
                .accessibilityLabel("PR shepherd owner archived or missing")
            }
        }
        .aiBeam(isActive: model.presentation.badge.isActive)
        .accessibilityValue(model.presentation.tooltip)
        .onAppear { model.refreshSessions() }
    }

    private func chip<Leading: View>(
        title: String,
        color: Color,
        textColor: Color,
        @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(spacing: 5) {
            leading()
                .foregroundStyle(textColor)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: 160)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.2), lineWidth: 0.75))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The session name, or the phase while the shepherd is acting on the PR.
    private func label(_ ownerTitle: String) -> String {
        guard model.presentation.badge.isActive else { return ownerTitle }
        let phase = model.presentation.phaseLine
        return phase.prefix(1).uppercased() + phase.dropFirst()
    }

    private func ownerLine(_ ownerTitle: String) -> String {
        let owner = [model.ownerAgent?.displayName, ownerTitle].compactMap { $0 }.joined(separator: " · ")
        let number = model.presentation.number.map { " \($0)" } ?? ""
        return "\(owner) is shepherding\(number) · \(model.presentation.phaseLine)"
    }
}
