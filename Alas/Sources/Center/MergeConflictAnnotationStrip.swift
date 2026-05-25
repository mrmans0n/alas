import SwiftUI

/// One-line strip below the merge-conflict toolbar that surfaces the AI
/// explanation for the current conflict. Collapsed by default to a single
/// truncated line; tapping anywhere expands to the full wrapped text, and
/// the `×` button hides the strip entirely for the lifetime of the current
/// annotation (it reappears when the annotation changes — e.g. user
/// navigates to the next conflict).
struct MergeConflictAnnotationStrip: View {
    let annotation: String

    @State private var isExpanded = false
    @State private var dismissedAnnotation: String?

    @Environment(\.theme) var theme

    var body: some View {
        if dismissedAnnotation == annotation {
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
                Button(action: { dismissedAnnotation = annotation }) {
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
            .onChange(of: annotation) { _, _ in
                // New annotation arrived (e.g., user navigated to another
                // conflict). Collapse back to the teaser so the user
                // doesn't get a wall of text without asking for it.
                isExpanded = false
            }
        }
    }
}
