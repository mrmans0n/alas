import SwiftUI

/// One-line strip below the merge-conflict toolbar that surfaces the AI
/// explanation for the current conflict. Collapsed by default to a single
/// truncated line; tapping anywhere expands to the full wrapped text, and
/// the `×` button hides the strip for this specific conflict (it reappears
/// for any other conflict the user navigates to).
///
/// Dismissal is keyed by `conflictKey` rather than `annotation` text so two
/// distinct conflicts that happen to produce identical one-line summaries
/// (common with repetitive import/order conflicts) don't share dismissal
/// state.
struct MergeConflictAnnotationStrip: View {
    let annotation: String
    /// Stable identity for the current conflict block — typically
    /// `MergeConflictTabModel.annotationKey(for:)`. Used as the dismissal
    /// key so dismissals follow the conflict, not the rendered sentence.
    let conflictKey: String

    @State private var isExpanded = false
    @State private var dismissedKeys: Set<String> = []

    @Environment(\.theme) var theme

    var body: some View {
        if dismissedKeys.contains(conflictKey) {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(theme.color("fg-subtle"))
                    .font(.system(size: 10))
                    .padding(.top, 2)
                Button(action: { isExpanded.toggle() }) {
                    Text(annotation)
                        .font(.system(size: 11))
                        .italic()
                        .foregroundColor(theme.color("fg-dim"))
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .textSelection(.enabled)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Click to expand")
                Button(action: {
                    dismissedKeys.insert(conflictKey)
                    // Also collapse so a future re-show (different conflict
                    // whose strip is not dismissed) starts on the teaser.
                    // The `.onChange(of: conflictKey)` below only fires
                    // while the visible branch is mounted; resetting here
                    // covers the dismiss-then-navigate path where the
                    // strip is unmounted before the key change.
                    isExpanded = false
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.color("fg-subtle"))
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
                .help("Dismiss this annotation")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(theme.color("bg-2"))
            .overlay(Divider(), alignment: .bottom)
            .onChange(of: conflictKey) { _, _ in
                // User navigated to another conflict. Collapse back to
                // the teaser so they don't get a wall of text without
                // asking for it.
                isExpanded = false
            }
        }
    }
}
