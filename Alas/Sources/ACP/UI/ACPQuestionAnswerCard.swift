import SwiftUI

/// The resolved form remains readable without keeping its input controls alive.
struct ACPQuestionAnswerCard: View {
    @Environment(\.designScale) private var scale
    @Environment(\.theme) private var theme
    let answer: ACPAnsweredQuestion
    var isExpanded: Bool = false
    var onExpandedChange: ((Bool) -> Void)?
    @State private var localExpanded = false

    private var expanded: Bool { onExpandedChange == nil ? localExpanded : isExpanded }
    private var hasDetails: Bool {
        answer.items.contains { !$0.options.isEmpty || $0.description?.isEmpty == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: scale.space[2]) {
                Image(systemName: "questionmark.bubble")
                Text(answer.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Question")
                Spacer(minLength: scale.space[2])
                Label(answer.statusLabel, systemImage: statusIcon)
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .font(scale.caption.font(weight: .medium))
            .foregroundStyle(theme.color("accent"))
            .padding(.horizontal, scale.space[3])
            .padding(.vertical, scale.space[2])
            .background(theme.color("accent").opacity(0.06))

            VStack(alignment: .leading, spacing: scale.space[3]) {
                if !answer.message.isEmpty {
                    Text(answer.message)
                        .font(scale.meta.font(weight: .medium))
                        .foregroundStyle(theme.color("fg"))
                        .textSelection(.enabled)
                }
                ForEach(answer.items.indices, id: \.self) { index in
                    let item = answer.items[index]
                    VStack(alignment: .leading, spacing: scale.space[1]) {
                        if item.question != answer.message {
                            Text(item.question)
                                .font(scale.meta.font(weight: .medium))
                                .foregroundStyle(theme.color("fg"))
                        }
                        if let text = item.answer {
                            Text(text)
                                .font(scale.metaFont)
                                .foregroundStyle(theme.color("accent"))
                        } else if answer.outcome == .answered {
                            Text("No answer provided")
                                .font(scale.metaFont)
                                .foregroundStyle(theme.color("fg-muted"))
                        }
                    }
                    .textSelection(.enabled)
                }
                if hasDetails {
                    Button {
                        if let onExpandedChange { onExpandedChange(!expanded) }
                        else { localExpanded.toggle() }
                    } label: {
                        HStack(spacing: scale.space[1]) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            Text(expanded ? "Hide details" : "Details")
                        }
                        .font(scale.caption.font(weight: .medium))
                        .foregroundStyle(theme.color("fg-muted"))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide question details" : "Show question details")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                }
                if expanded {
                    details
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(scale.space[3])
        }
        .background(theme.color("bg-1").opacity(0.65))
        .clipShape(.rect(cornerRadius: scale.radius.medium))
        .overlay {
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), lineWidth: 1)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            Divider()
            ForEach(answer.items.indices, id: \.self) { index in
                let item = answer.items[index]
                if !item.options.isEmpty || item.description?.isEmpty == false {
                    VStack(alignment: .leading, spacing: scale.space[2]) {
                        Text(item.question)
                            .font(scale.caption.font(weight: .semibold))
                        if let description = item.description, !description.isEmpty {
                            Text(description)
                                .font(scale.metaFont)
                        }
                        ForEach(item.options.indices, id: \.self) { optionIndex in
                            let option = item.options[optionIndex]
                            HStack(alignment: .top, spacing: scale.space[2]) {
                                Image(systemName: option.selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(theme.color(option.selected ? "accent" : "fg-faint"))
                                VStack(alignment: .leading, spacing: scale.space[1]) {
                                    Text(option.title)
                                    if let description = option.description, !description.isEmpty {
                                        Text(description)
                                            .foregroundStyle(theme.color("fg-muted"))
                                    }
                                }
                            }
                            .font(scale.metaFont)
                        }
                    }
                }
            }
        }
        .foregroundStyle(theme.color("fg-muted"))
        .textSelection(.enabled)
    }

    private var statusIcon: String {
        switch answer.outcome {
        case .answered: "checkmark"
        case .skipped: "forward"
        case .cancelled: "xmark"
        case .opened: "arrow.up.right"
        }
    }
}
