import SwiftUI

struct EmptyState: View {
    let canCreateWorktree: Bool
    let onAddProject: () -> Void
    let onNewWorktree: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 18) {
                ZStack {
                    LinearGradient(colors: [theme.color("bg-3"), theme.color("bg-2")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(width: 90, height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(theme.color("line"), lineWidth: 0.5))
                    Image(systemName: "airplane")
                        .font(.system(size: 38))
                        .foregroundColor(theme.color("accent"))
                }
                VStack(spacing: 6) {
                    Text("No projects yet")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(theme.color("fg"))
                    Text("Add a git repository to get started, then create a worktree to begin work.")
                        .font(.system(size: 13))
                        .foregroundColor(theme.color("fg-dim"))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                HStack(spacing: 8) {
                    AlasButton(title: "Add repository", icon: "folder", style: .primary, action: onAddProject)
                    AlasButton(title: "New worktree", icon: "plus", style: .normal, action: onNewWorktree)
                        .disabled(!canCreateWorktree)
                        .opacity(canCreateWorktree ? 1 : 0.5)
                }
                HStack(spacing: 10) {
                    HStack(spacing: 4) { Kbd(label: "⌘ P")
                    Text("switch").font(.system(size: 11)) }
                    HStack(spacing: 4) { Kbd(label: "⌥ ⌘ N")
                    Text("new").font(.system(size: 11)) }
                    HStack(spacing: 4) { Kbd(label: "⌘ ,")
                    Text("settings").font(.system(size: 11)) }
                }
                .foregroundColor(theme.color("fg-faint"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.color("bg-1"))

            TrafficLights()
                .padding(.leading, 12)
                .padding(.top, 10)
        }
        .windowDragHandle()
    }
}
