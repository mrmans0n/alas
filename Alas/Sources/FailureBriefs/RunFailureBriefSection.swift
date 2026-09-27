import SwiftUI

struct RunFailureBriefPresentation: Equatable {
    enum Row: Equatable {
        case line(number: Int, text: String)
        case gap
    }

    enum Suggestion: Equatable {
        case generating
        case ready(RunFailureBrief)
        case none
    }

    let observedTitle: String
    let rows: [Row]
    let truncationNote: String?
    let suggestion: Suggestion

    init?(state: RunFailureBriefCoordinator.State?) {
        guard let state, let excerpt = state.excerpt, !excerpt.lines.isEmpty else { return nil }
        observedTitle = excerpt.matchedErrors ? "Observed errors" : "Last lines of output"
        var rows: [Row] = []
        for line in excerpt.lines {
            if case let .line(previous, _) = rows.last, line.number > previous + 1 { rows.append(.gap) }
            rows.append(.line(number: line.number, text: line.text))
        }
        self.rows = rows
        truncationNote = excerpt.truncated ? "Earlier lines omitted" : nil
        suggestion = switch state {
        case .generating: .generating
        case let .ready(_, brief): .ready(brief)
        case .unavailable: .none
        }
    }
}

struct RunFailureBriefSection: View {
    let presentation: RunFailureBriefPresentation
    let codeFont: NSFont

    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                observed
                suggested
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 280)
        .fixedSize(horizontal: false, vertical: true)
        .background(theme.color("bg-1"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
        .accessibilityIdentifier("run-failure-brief")
    }

    private var observed: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionTitle(presentation.observedTitle)
                if let note = presentation.truncationNote {
                    Text(note).font(.system(size: 10)).foregroundStyle(theme.color("fg-faint"))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(presentation.rows.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case let .line(number, text):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(number)")
                                .foregroundStyle(theme.color("fg-faint"))
                                .frame(minWidth: 36, alignment: .trailing)
                            Text(text).foregroundStyle(theme.color("fg"))
                        }
                    case .gap:
                        Text("⋯").foregroundStyle(theme.color("fg-faint")).padding(.leading, 44)
                    }
                }
            }
            .font(Font(codeFont as CTFont))
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var suggested: some View {
        switch presentation.suggestion {
        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarizing on-device…").font(.system(size: 11)).foregroundStyle(theme.color("fg-dim"))
            }
        case let .ready(brief):
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Suggested — on-device model, may be wrong")
                Text(brief.summary).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.color("fg"))
                Text(brief.cause).font(.system(size: 12)).foregroundStyle(theme.color("fg"))
                ForEach(brief.checks, id: \.self) { check in
                    Label(check, systemImage: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.color("fg-dim"))
                }
            }
            .textSelection(.enabled)
        case .none:
            EmptyView()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.color("fg-dim"))
    }
}
