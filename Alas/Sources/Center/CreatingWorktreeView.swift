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

    var body: some View {
        ForestLoadingView(message: phrase)
    }
}
