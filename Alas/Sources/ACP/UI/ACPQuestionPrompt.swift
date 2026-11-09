import SwiftUI

struct ACPQuestionPrompt: View {
    @Environment(\.designScale) private var scale
    @ObservedObject var session: ACPSession
    let onRespond: (ACPQuestionResponse) -> Void
    @Environment(\.theme) private var theme
    @State private var selection: [String: Set<String>] = [:]

    var body: some View {
        if let pending = session.transcript.pendingQuestion {
            content(for: pending.params)
        }
    }

    @ViewBuilder
    private func content(for params: ACPQuestionRequestParams) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(params)
            questionBody(params)
            actionRow(params)
        }
        .background(
            LinearGradient(
                colors: [theme.color("bg-2").opacity(0.72), theme.color("bg-1").opacity(0.62)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        )
        .shadow(color: theme.color("accent").opacity(0.10), radius: 16, y: 4)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    @ViewBuilder
    private func header(_ params: ACPQuestionRequestParams) -> some View {
        HStack(spacing: scale.space[2]) {
            ZStack {
                RoundedRectangle(cornerRadius: scale.radius.small)
                    .fill(theme.color("accent").opacity(0.18))
                Image(systemName: "questionmark.bubble")
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("accent"))
            }
            .frame(width: 18, height: 18)

            Text("Question")
                .font(scale.caption.font(weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))

            if let title = params.title, !title.isEmpty {
                Text("· \(title)")
                    .font(scale.metaFont)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(theme.color("fg-faint"))
            }

            Spacer(minLength: 6)

            QuestionPendingPulse()
                .frame(width: 6, height: 6)
            Text("Awaiting input")
                .font(scale.caption.font(weight: .semibold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("accent").opacity(0.08))
    }

    @ViewBuilder
    private func questionBody(_ params: ACPQuestionRequestParams) -> some View {
        VStack(alignment: .leading, spacing: scale.space[3]) {
            ForEach(params.questions) { question in
                VStack(alignment: .leading, spacing: scale.space[2]) {
                    Text(question.prompt)
                        .font(scale.meta.font(weight: .semibold))
                        .foregroundStyle(theme.color("fg"))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: scale.space[2]) {
                        ForEach(question.options) { option in
                            optionRow(option: option, question: question)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[3])
    }

    @ViewBuilder
    private func optionRow(option: ACPQuestionOption, question: ACPQuestion) -> some View {
        let selected = selection[question.id]?.contains(option.id) == true
        Button {
            toggle(option: option, for: question)
        } label: {
            HStack(spacing: scale.space[2]) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(scale.bodyFont)
                    .foregroundStyle(selected ? theme.color("accent") : theme.color("fg-faint"))
                    .frame(width: 16)
                Text(option.label)
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[2])
            .padding(.vertical, scale.space[2])
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.color("accent").opacity(0.12) : theme.color("bg-0").opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(selected ? theme.color("accent").opacity(0.5) : theme.color("line"), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionRow(_ params: ACPQuestionRequestParams) -> some View {
        let answer = Self.answeredResponse(for: params, selection: selection)
        HStack(spacing: scale.space[2]) {
            Button("Skip") {
                onRespond(.init(outcome: .skipped(reason: nil)))
            }
            .buttonStyle(QuestionSecondaryButtonStyle(theme: theme))

            Button("Cancel") {
                onRespond(.init(outcome: .cancelled))
            }
            .buttonStyle(QuestionSecondaryButtonStyle(theme: theme))

            Spacer()

            Button("Answer") {
                if let answer {
                    onRespond(answer)
                }
            }
            .buttonStyle(QuestionPrimaryButtonStyle(theme: theme, disabled: answer == nil))
            .disabled(answer == nil)
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-1").opacity(0.55))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.color("line-soft")).frame(height: 0.5)
        }
    }

    private func toggle(option: ACPQuestionOption, for question: ACPQuestion) {
        let allowMultiple = question.allowMultiple == true
        if allowMultiple {
            var current = selection[question.id] ?? []
            if current.contains(option.id) {
                current.remove(option.id)
            } else {
                current.insert(option.id)
            }
            selection[question.id] = current
        } else {
            selection[question.id] = [option.id]
        }
    }

    static func answeredResponse(
        for params: ACPQuestionRequestParams,
        selection: [String: Set<String>]
    ) -> ACPQuestionResponse? {
        var answers: [ACPQuestionAnswer] = []
        for question in params.questions {
            let selected = selection[question.id] ?? []
            guard !selected.isEmpty else { return nil }
            let ordered = question.options.map(\.id).filter { selected.contains($0) }
            answers.append(.init(questionId: question.id, selectedOptionIds: ordered))
        }
        return .init(outcome: .answered(answers: answers))
    }
}

private struct QuestionPrimaryButtonStyle: ButtonStyle {
    @Environment(\.designScale) private var scale
    let theme: Theme
    let disabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(scale.meta.font(weight: .semibold))
            .padding(.horizontal, scale.space[3])
            .frame(height: 26)
            .background(theme.color("accent").opacity(disabled ? 0.16 : (configuration.isPressed ? 0.78 : 0.95)))
            .foregroundStyle(disabled ? theme.color("fg-faint") : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
    }
}

private struct QuestionSecondaryButtonStyle: ButtonStyle {
    @Environment(\.designScale) private var scale
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(scale.meta.font(weight: .medium))
            .padding(.horizontal, scale.space[2])
            .frame(height: 26)
            .background(theme.color("bg-0").opacity(configuration.isPressed ? 0.8 : 0.55))
            .foregroundStyle(theme.color("fg-muted"))
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
    }
}

private struct QuestionPendingPulse: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Circle()
            .fill(theme.color("accent"))
            .overlay(
                Circle()
                    .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 2)
                    .scaleEffect(1.5)
                    .opacity(0.35)
            )
    }
}
