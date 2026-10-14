import SwiftUI

/// Collapsed-by-default reasoning row. Short, single-line thoughts appear
/// in the disclosure itself; longer thoughts remain behind "Thinking…".
struct ACPThoughtView: View {
    @ObservedObject var buffer: StreamingText
    /// Whether the agent is still writing into this thought. Decided by
    /// `ACPNarrationLiveness` at the transcript level, since the buffer
    /// alone cannot tell "finished" from "paused between chunks".
    var isLive: Bool = false
    /// Reports each toggle, so the transcript can remember it across rebuilds.
    var onExpandedChange: ((Bool) -> Void)?
    @State private var expanded: Bool
    @Environment(\.theme) private var theme

    init(
        buffer: StreamingText, isLive: Bool = false,
        initiallyExpanded: Bool = false, onExpandedChange: ((Bool) -> Void)? = nil
    ) {
        self.buffer = buffer
        self.isLive = isLive
        self.onExpandedChange = onExpandedChange
        _expanded = State(initialValue: initiallyExpanded)
    }

    static func inlineLabel(for value: String) -> String? {
        // Live buffers can grow into long walls of text. Stop before making
        // a trimmed copy on every subsequent streaming tick.
        guard value.utf8.prefix(1025).count <= 1024 else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isNewline) else { return nil }
        let text: Substring
        if trimmed.hasPrefix("**"),
           trimmed.hasSuffix("**"),
           trimmed.count >= 4,
           !trimmed.dropFirst(2).dropLast(2).contains("**") {
            let unmarked = trimmed.dropFirst(2).dropLast(2)
            guard unmarked.contains(where: { !$0.isWhitespace }) else { return nil }
            text = unmarked
        } else {
            text = trimmed[...]
        }
        guard !text.isEmpty, text.count <= 80 else { return nil }
        return String(text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.color("bg-4"))
                .frame(width: 1.5)
                .acpNarrationShimmer(isActive: isLive, axis: .vertical)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    expanded.toggle()
                    onExpandedChange?(expanded)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "brain")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                        Text(expanded ? "Hide thinking" : (Self.inlineLabel(for: buffer.value) ?? "Thinking…"))
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .acpNarrationShimmer(isActive: isLive)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    Text(buffer.value)
                        .font(.system(size: 12, design: .default).italic())
                        .foregroundStyle(theme.color("fg-dim"))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
