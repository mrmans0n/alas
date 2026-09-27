import SwiftUI

/// Strip below the merge-conflict toolbar that shows the advisory local-model
/// explanation for the current hunk. Collapsed it shows the hunk citation and
/// the cause; tapping expands to each side's intent. The `×` hides the strip
/// for this hunk only.
///
/// Dismissal is keyed by `conflictKey` rather than the text so two hunks with
/// identical explanations don't share dismissal state.
struct MergeConflictAnnotationStrip: View {
    let explanation: MergeConflictExplanation
    /// Identifies the hunk the explanation describes, e.g. "Conflict 2 of 5, lines 40–52".
    let citation: String
    let localLabel: String
    let remoteLabel: String
    /// `MergeConflictTabModel.conflictKey(for:)` of the current hunk.
    let conflictKey: String
    /// Owned by the parent so dismissal survives this strip unmounting while
    /// the user visits a hunk with no explanation.
    @Binding var dismissedKeys: Set<String>

    @State private var isExpanded = false

    @Environment(\.theme) var theme

    var body: some View {
        if dismissedKeys.contains(conflictKey) {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "text.bubble")
                    .foregroundColor(theme.color("fg-subtle"))
                    .font(.system(size: 10))
                    .padding(.top, 2)
                Button(action: { isExpanded.toggle() }) {
                    VStack(alignment: .leading, spacing: 3) {
                        (Text(verbatim: "Advisory · \(citation): ").fontWeight(.medium) + Text(explanation.cause))
                            .lineLimit(isExpanded ? nil : 1)
                            .truncationMode(.tail)
                        if isExpanded {
                            Text(verbatim: "LOCAL (\(localLabel)): \(explanation.localIntent)")
                            Text(verbatim: "REMOTE (\(remoteLabel)): \(explanation.remoteIntent)")
                            Text("On-device explanation. It may be wrong and changes nothing in the file.")
                                .foregroundColor(theme.color("fg-subtle"))
                        }
                    }
                    .font(.system(size: 11))
                    .italic()
                    .foregroundColor(theme.color("fg-dim"))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .textSelection(.enabled)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Click to expand")
                Button(action: {
                    dismissedKeys.insert(conflictKey)
                    // The `.onChange(of: conflictKey)` below only fires while
                    // this branch is mounted, so reset here for dismiss-then-navigate.
                    isExpanded = false
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.color("fg-subtle"))
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
                .help("Dismiss this explanation")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.color("bg-2"))
            .overlay(Divider(), alignment: .bottom)
            .onChange(of: conflictKey) { _, _ in
                isExpanded = false
            }
        }
    }
}
