import SwiftUI

/// Whether the Alas agent skills (`alas skill install`) are in place, as
/// `alas skill status --json` reports them.
enum AlasSkillsState: String {
    case missing
    case outdated
    case installed
    /// A skill Alas did not install has one of Alas's skill names.
    case conflict
    case unknown
}

/// Installs, updates or removes the Alas agent skills: stubs that teach any
/// agent to drive Alas with the `alas` CLI, for agents whose MCP policy blocks
/// or caps the built-in server. The user decides; nothing installs on its own.
struct AlasSkillsControl: View {
    @Environment(\.designScale) private var scale
    @Environment(\.theme) private var theme
    let state: AppState
    @State private var skills: AlasSkillsState = .unknown
    @State private var running = false

    var body: some View {
        HStack(spacing: scale.space[2]) {
            if running {
                ProgressView().controlSize(.small)
            } else {
                switch skills {
                case .missing:
                    AlasButton(title: "Install skills", style: .subtle) { run(state.installAlasSkills) }
                case .outdated, .conflict:
                    // A conflict hides how much of Alas's set is installed, and
                    // removal leaves the other skill alone, so offer both.
                    AlasButton(title: skills == .outdated ? "Update skills" : "Install skills", style: .subtle) {
                        run(state.installAlasSkills)
                    }
                    AlasButton(title: "Remove", style: .subtle) { run(state.removeAlasSkills) }
                case .installed:
                    AlasButton(title: "Remove skills", style: .subtle) { run(state.removeAlasSkills) }
                case .unknown:
                    EmptyView()
                }
            }
            if let note {
                Text(note)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color(skills == .conflict ? "warn" : "fg-dim"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { skills = await state.alasSkillsState() }
    }

    private var note: String? {
        switch skills {
        case .installed: "Installed"
        case .outdated: "An older version is installed"
        case .conflict: "Another skill uses an Alas skill name; Alas leaves it alone"
        case .unknown: "The alas CLI is not available"
        case .missing: nil
        }
    }

    private func run(_ action: @escaping () async -> Bool) {
        running = true
        Task {
            _ = await action()
            skills = await state.alasSkillsState()
            running = false
        }
    }
}
