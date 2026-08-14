import AppKit
import SwiftUI

struct RunScriptFailureBannerPresentation: Equatable {
    let failure: RunScriptFailure
    let overflowCount: Int

    init(failure: RunScriptFailure, overflowCount: Int = 0) {
        self.failure = failure
        self.overflowCount = overflowCount
    }

    init?(failures: [RunScriptFailure]) {
        guard let newest = failures.max(by: { $0.completedAt < $1.completedAt }) else { return nil }
        failure = newest
        overflowCount = max(0, failures.count - 1)
    }

    var title: String {
        "\(failure.scriptName) failed with exit code \(failure.exitCode)"
    }

    var overflowText: String? {
        overflowCount > 0 ? "\(overflowCount) more" : nil
    }
}

struct RunScriptFailureDetailPresentation: Equatable {
    let failure: RunScriptFailure

    var outputText: String {
        switch failure.capturedOutput {
        case .available(let text, _):
            text.isEmpty ? "No output was captured." : text
        case .unavailable:
            "Output could not be captured."
        }
    }

    var outputFooter: String? {
        if case .available(_, true) = failure.capturedOutput {
            "Output truncated"
        } else {
            nil
        }
    }

    var completedText: String {
        failure.completedAt.formatted(date: .abbreviated, time: .standard)
    }
}

struct RunScriptFailureBanner: View {
    let presentation: RunScriptFailureBannerPresentation
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.color("del"))
                    Text(presentation.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.color("fg"))
                    if let overflowText = presentation.overflowText {
                        Text(overflowText)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-muted"))
                    }
                    Spacer(minLength: 0)
                    Text("Show output")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("accent"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(presentation.title). Show output.")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.color("fg-muted"))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss run script failure")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(theme.color("del").opacity(0.12))
        .overlay(Rectangle().fill(theme.color("line")).frame(height: 0.5), alignment: .bottom)
        .accessibilityIdentifier("run-script-failure-banner")
    }
}

struct RunScriptFailureDetailView: View {
    let failure: RunScriptFailure
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        let presentation = RunScriptFailureDetailPresentation(failure: failure)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(failure.scriptName) failed")
                        .font(.headline)
                    Text("Exit code \(failure.exitCode) on \(failure.branch)")
                        .font(.subheadline)
                        .foregroundStyle(theme.color("fg-muted"))
                    Text("Completed \(presentation.completedText)")
                        .font(.caption)
                        .foregroundStyle(theme.color("fg-muted"))
                }
                Spacer()
                Button("Copy Output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(presentation.outputText, forType: .string)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                Text(presentation.outputText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(theme.color("bg-2"))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.color("line"), lineWidth: 1))
            .clipShape(.rect(cornerRadius: 8))

            if let outputFooter = presentation.outputFooter {
                Text(outputFooter)
                    .font(.caption)
                    .foregroundStyle(theme.color("fg-muted"))
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
        .background(theme.color("bg-1"))
    }
}
