import SwiftUI

struct CreatingWorktreeView: View {
    private static let phrases: [String] = [
        "Reticulating splines…",
        "Herding git objects…",
        "Polishing branches…",
        "Spinning up the universe…",
        "Mixing the terminal sauce…",
        "Assembling worktree scaffolding…",
        "Charging the flux capacitor…",
        "Aligning cosmic rays…",
        "Waking the daemons…",
        "Brewing fresh commits…",
        "Calibrating git-fluence…",
        "Untangling branches…",
        "Loading witty phrases…",
        "Inflating the worktree…",
        "Summoning the merge spirits…",
    ]

    let worktree: Worktree

    @State private var phrase: String = Self.phrases.randomElement() ?? Self.phrases[0]
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Spinner()
                .frame(width: 32, height: 32)
            Text(phrase)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}
