import SwiftUI

struct AiSplitButton: View {
    let availableTools: [CommitAITool]
    @Binding var selectedToolId: String
    let busy: Bool
    let onGenerate: () -> Void

    @Environment(\.theme) var theme

    private var selected: CommitAITool? {
        CommitAITool(rawValue: selectedToolId)
    }

    /// True when no usable tool is selected — disables the primary button.
    /// `busy` is deliberately NOT included here: the primary button doubles
    /// as a cancel affordance while a generation is in flight, so it must
    /// remain clickable to let the user stop a slow CLI.
    private var primaryDisabled: Bool {
        selected == nil || selected == CommitAITool.none
    }

    var body: some View {
        HStack(spacing: 1) {
            Button(action: onGenerate) {
                HStack(spacing: 6) {
                    if busy {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    } else {
                        Text("✨").font(.system(size: 11))
                    }
                    Text(busy ? "Cancel" : (selected?.label ?? "None"))
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundColor(primaryDisabled ? theme.color("fg-faint") : theme.color("fg"))
                .background(theme.color("bg-3"))
            }
            .buttonStyle(.plain)
            .disabled(primaryDisabled)
            .help(primaryDisabled
                  ? "Pick a tool in Settings → Changes to enable"
                  : busy
                      ? "Cancel generation"
                      : "Generate commit message with \(selected!.label)")

            Menu {
                ForEach(menuTools, id: \.id) { tool in
                    Button {
                        selectedToolId = tool.id
                    } label: {
                        HStack {
                            Text(tool.label)
                            if tool.id == selectedToolId {
                                Icon(name: "check", size: 10)
                            }
                        }
                    }
                }
                Divider()
                Button("None") { selectedToolId = CommitAITool.none.id }
            } label: {
                Icon(name: "chev-down", size: 9, color: theme.color("fg-faint"))
                    .padding(.horizontal, 7).padding(.vertical, 7)
                    .background(theme.color("bg-3"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var menuTools: [CommitAITool] {
        availableTools.isEmpty
            ? CommitAITool.detectable          // show all so user knows what's possible
            : availableTools
    }
}
