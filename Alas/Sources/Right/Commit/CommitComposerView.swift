import SwiftUI

struct CommitComposerView: View {
    @Bindable var state: CommitComposerState
    let stagedCount: Int
    let stagedAdd: Int
    let stagedDel: Int
    let branchName: String?
    let availableTools: [CommitAITool]
    @Binding var aiToolId: String
    let onGenerate: () -> Void
    let onCommit: () -> Void
    let onAmendToggle: (Bool) -> Void   // delegates prefill / warning work

    @Environment(\.theme) var theme
    @FocusState private var focused: Field?
    private enum Field: Hashable { case subject, body }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.expanded {
                expanded
            } else {
                collapsed
            }
            if let err = state.error {
                InlineErrorStrip(message: err, onDismiss: { state.error = nil })
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var collapsed: some View {
        Button(action: { state.expanded = true }) {
            HStack(spacing: 8) {
                Icon(name: "commit", size: 11, color: theme.color("fg-dim"))
                Text("Commit").font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Spacer()
                Text("\(stagedCount) staged file\(stagedCount == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                HStack(spacing: 4) {
                    Text("+\(stagedAdd)").foregroundColor(theme.color("add"))
                    Text("−\(stagedDel)").foregroundColor(theme.color("del"))
                }
                .font(.system(size: 11, design: .monospaced))
                Text("Write message")
                    .font(.system(size: 11)).foregroundColor(theme.color("accent"))
                Icon(name: "chev-right", size: 10, color: theme.color("fg-faint"))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Icon(name: "commit", size: 11, color: theme.color("fg-dim"))
                Text("Commit").font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                if let b = branchName {
                    Text("to ").font(.system(size: 11)).foregroundColor(theme.color("fg-faint"))
                    Text(b).font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                } else {
                    Text("(detached)").font(.system(size: 11)).foregroundColor(theme.color("fg-faint"))
                }
                Spacer()
                Text("\(stagedCount) file\(stagedCount == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg-dim"))
                HStack(spacing: 4) {
                    Text("+\(stagedAdd)").foregroundColor(theme.color("add"))
                    Text("−\(stagedDel)").foregroundColor(theme.color("del"))
                }
                .font(.system(size: 11, design: .monospaced))
                Button(action: { state.expanded = false }) {
                    Icon(name: "chev-down", size: 10, color: theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)

            TextField("Subject — short, present tense", text: $state.subject)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(theme.color("fg"))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(theme.color("bg-2"))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.color("line-soft"), lineWidth: 0.5)
                )
                .focused($focused, equals: .subject)
                .padding(.horizontal, 12)
                .disabled(state.busy)
                .onSubmit(commitIfAllowed)

            TextEditor(text: $state.body)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 64, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .background(theme.color("bg-2"))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(theme.color("line-soft"), lineWidth: 0.5)
                )
                .focused($focused, equals: .body)
                .padding(.horizontal, 12)
                .disabled(state.busy)

            HStack(spacing: 8) {
                AiSplitButton(
                    availableTools: availableTools,
                    selectedToolId: $aiToolId,
                    busy: state.busy,
                    onGenerate: onGenerate
                )

                Toggle(isOn: Binding(
                    get: { state.amend },
                    set: { newVal in
                        state.amend = newVal
                        onAmendToggle(newVal)
                    }
                )) {
                    Text("Amend").font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
                }
                .toggleStyle(.checkbox)
                .disabled(!state.canAmend)
                .help(state.canAmend ? "" : "No previous commit to amend")

                Spacer()

                Button(action: commitIfAllowed) {
                    HStack(spacing: 6) {
                        Text(state.amend ? "Amend" : "Commit")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text("⌘⏎").font(.system(size: 10)).opacity(0.6)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundColor(.white)
                    .background(state.canCommit(stagedCount: stagedCount)
                                ? theme.color("accent")
                                : theme.color("accent").opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!state.canCommit(stagedCount: stagedCount))
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12)

            if state.amend && state.amendWarning {
                Text("Amending a pushed commit will rewrite history.")
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.color("warn"))
                    .padding(.horizontal, 12)
            }
        }
        .onAppear { focused = .subject }
    }

    private func commitIfAllowed() {
        guard state.canCommit(stagedCount: stagedCount) else { return }
        onCommit()
    }
}
