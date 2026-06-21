import SwiftUI

/// Icon-only menu exposing branch operations (merge / rebase) for the
/// current worktree. Lives in the Commits section header next to
/// `BaseBranchSelector`. Owns its own popover state for the branch
/// pickers so callers don't need to thread state through.
struct BranchOpsMenu: View {
    let rps: RightPaneState

    @State private var pendingMergeBranch: String = ""
    @State private var pendingRebaseOnto: String = ""
    @State private var branchesForPicker: [String] = []
    @State private var branchesLoading: Bool = false
    @State private var showMergePicker: Bool = false
    @State private var showRebasePicker: Bool = false

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            Button("Merge branch into this worktree…") { openMergePicker() }
            Button("Rebase this worktree onto…")      { openRebasePicker() }
            Divider()
            Button("Fetch now") { rps.fetchNow() }
        } label: {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("fg-muted"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Branch operations")
        .popover(isPresented: $showMergePicker, arrowEdge: .bottom) {
            pickerSheet(title: "Merge into current",
                        actionLabel: "Merge",
                        selection: $pendingMergeBranch,
                        onConfirm: {
                            guard !pendingMergeBranch.isEmpty else { return }
                            rps.runMerge(branch: pendingMergeBranch)
                            showMergePicker = false
                            pendingMergeBranch = ""
                        })
        }
        .popover(isPresented: $showRebasePicker, arrowEdge: .bottom) {
            pickerSheet(title: "Rebase current onto",
                        actionLabel: "Rebase",
                        selection: $pendingRebaseOnto,
                        onConfirm: {
                            guard !pendingRebaseOnto.isEmpty else { return }
                            rps.runRebase(onto: pendingRebaseOnto)
                            showRebasePicker = false
                            pendingRebaseOnto = ""
                        })
        }
    }

    @ViewBuilder
    private func pickerSheet(title: String,
                             actionLabel: String,
                             selection: Binding<String>,
                             onConfirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
            BranchPicker(
                selection: selection,
                branches: branchesForPicker,
                isLoading: branchesLoading,
                errorMessage: nil
            )
            .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") {
                    showMergePicker = false
                    showRebasePicker = false
                }
                Button(actionLabel, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.wrappedValue.isEmpty)
            }
        }
        .padding(12)
    }

    private func openMergePicker() {
        Task { await loadBranches() }
        showMergePicker = true
    }

    private func openRebasePicker() {
        Task { await loadBranches() }
        showRebasePicker = true
    }

    private func loadBranches() async {
        branchesLoading = true
        defer { branchesLoading = false }
        let svc = GitService()
        if let list = try? await svc.branches(at: rps.worktree.path) {
            branchesForPicker = list
        }
    }
}
