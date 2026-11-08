import SwiftUI

struct BranchPicker: View {
    @Environment(\.designScale) private var scale
    @Binding var selection: String
    let branches: [String]
    let isLoading: Bool
    let errorMessage: String?

    @Environment(\.theme) var theme
    @State private var open = false
    @State private var search = ""

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 6) {
                Text(selection.isEmpty ? "Choose a branch" : selection)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if isLoading {
                    Spinner(lineWidth: 1.5, duration: 0.7)
                        .frame(width: 12, height: 12)
                }
                Image(systemName: "chevron.down")
                    .font(scale.glyphFont)
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, scale.space[2])
            .frame(height: 28)
            .background(theme.color("bg-1"))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popoverBody
        }
    }

    private var filteredBranches: [String] {
        if search.isEmpty { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    private var selectionIsListed: Bool {
        selection.isEmpty || branches.contains(selection)
    }

    @ViewBuilder
    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                AlasField(text: $selection, placeholder: "Branch or ref", monospaced: true)
                AlasField(text: $search, placeholder: "Search branches...")
            }
            .padding(scale.space[2])

            Divider().background(theme.color("line"))

            if let errorMessage {
                Text(errorMessage)
                    .font(scale.metaFont)
                    .foregroundColor(.red)
                    .padding(.horizontal, scale.space[3])
                    .padding(.vertical, scale.space[2])
                Divider().background(theme.color("line"))
            }

            if branches.isEmpty {
                Text(isLoading ? "Loading branches..." : "No branches found")
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(scale.space[3])
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !selectionIsListed {
                            row(name: selection, note: "manual")
                            Divider().background(theme.color("line"))
                        }
                        ForEach(filteredBranches, id: \.self) { branch in
                            row(name: branch)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }

    @ViewBuilder
    private func row(name: String, note: String? = nil) -> some View {
        Button(action: {
            selection = name
            open = false
        }) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(scale.caption.font(weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .opacity(name == selection ? 1 : 0)
                Text(name)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    Text(note)
                        .font(scale.caption.font(weight: .regular))
                        .foregroundColor(theme.color("fg-dim"))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[2])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
