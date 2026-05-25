import SwiftUI

struct MergeConflictToolbar: View {
    let conflictCount: Int
    let currentConflictIndex: Int?
    /// True once the conflicted file has been loaded successfully (binary
    /// or text). Gates `Mark resolved` so it can't fire on an empty initial
    /// buffer. Stays true for binaries — the user resolves them via the
    /// right-pane Use ours/theirs context menu, then clicks Mark resolved here.
    let isLoaded: Bool
    /// True only when a loaded file is text-based (non-binary). Gates the
    /// agent + 3-column-only actions (prev/next, accept LOCAL/REMOTE/BOTH).
    let canRunAgent: Bool
    let agentBusy: Bool
    let hasAgent: Bool
    /// True while an unreviewed agent proposal is on screen. The toolbar
    /// stays interactive at the edges of the overlay; this gate prevents
    /// the user from kicking off a second agent run that would silently
    /// clobber the pending proposal.
    let hasPendingProposal: Bool
    @Binding var showBase: Bool
    @Binding var wordDiffMode: MergeWordDiff.Mode
    /// True only when the merged file actually contains zdiff3 `|||||||`
    /// markers. Off for merges driven from outside alas without
    /// `merge.conflictStyle=zdiff3`, where the toggle would do nothing.
    let baseAvailable: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onAskAgentResolve: () -> Void
    let onMarkResolved: () -> Void

    @Environment(\.theme) var theme

    var body: some View {
        HStack(spacing: 8) {
            counter
            Divider().frame(height: 18)
            navigationButtons
            Divider().frame(height: 18)
            Picker("Highlight words", selection: $wordDiffMode) {
                Text("Off").tag(MergeWordDiff.Mode.off)
                Text("Characters").tag(MergeWordDiff.Mode.characters)
                Text("Words").tag(MergeWordDiff.Mode.words)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 150)
            .help("Highlight character or word-level differences inside conflict hunks")
            Spacer()
            Button(action: onAskAgentResolve) {
                HStack(spacing: 4) {
                    if agentBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("Ask agent to resolve")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canRunAgent || !hasAgent || agentBusy || hasPendingProposal)
            .help(hasAgent
                ? "Run the configured agent on the whole file and preview its proposal"
                : "Configure an agent in Settings to enable this")
            Toggle("Show BASE", isOn: $showBase)
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(!baseAvailable)
                .help(baseAvailable
                    ? "Show the common-ancestor BASE lines inside each conflict region"
                    : "This file has no BASE markers. Run the merge with merge.conflictStyle=zdiff3 to enable BASE.")
            Button(action: onMarkResolved) {
                Text("Mark resolved")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!isLoaded || conflictCount > 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(theme.color("bg-1"))
        .overlay(Divider(), alignment: .bottom)
    }

    private var counter: some View {
        Text(counterText)
            .font(.system(size: 11))
            .foregroundColor(theme.color("fg-dim"))
    }

    private var counterText: String {
        if conflictCount == 0 {
            return "All resolved"
        }
        if let idx = currentConflictIndex {
            return "Conflict \(idx + 1) of \(conflictCount)"
        }
        return "\(conflictCount) conflict(s)"
    }

    private var navigationButtons: some View {
        HStack(spacing: 4) {
            ChevronNavButton(
                systemName: "chevron.up",
                tooltip: "Previous conflict (⌥↑)",
                shortcut: .upArrow,
                disabled: conflictCount == 0,
                action: onPrevious
            )
            ChevronNavButton(
                systemName: "chevron.down",
                tooltip: "Next conflict (⌥↓)",
                shortcut: .downArrow,
                disabled: conflictCount == 0,
                action: onNext
            )
        }
    }
}

/// Icon-only chevron button matching the worktree `+` button styling: a
/// fixed-size hit area with a hover background and tinted icon. Plain
/// borderless buttons in a toolbar read as text, which is what the user
/// flagged — this gives prev/next a real affordance.
private struct ChevronNavButton: View {
    let systemName: String
    let tooltip: String
    let shortcut: KeyEquivalent
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.theme) var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(disabled
                    ? theme.color("fg-faint")
                    : (hovering ? theme.color("fg") : theme.color("fg-muted")))
                .frame(width: 20, height: 20)
                .background(hovering && !disabled ? theme.color("bg-4") : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: [.option])
        .help(tooltip)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}
