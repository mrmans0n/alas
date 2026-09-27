import SwiftUI

struct RunScriptFailureBannerPresentation: Equatable {
    let failure: RunScriptFailure
    let overflowCount: Int
    let brief: RunFailureBriefCoordinator.State?

    init(failure: RunScriptFailure, overflowCount: Int = 0, brief: RunFailureBriefCoordinator.State? = nil) {
        self.failure = failure
        self.overflowCount = overflowCount
        self.brief = brief
    }

    init?(failures: [RunScriptFailure]) {
        guard let newest = failures.max(by: { $0.completedAt < $1.completedAt }) else { return nil }
        failure = newest
        overflowCount = max(0, failures.count - 1)
        brief = nil
    }

    var detail: String? {
        switch brief {
        case .generating: "Summarizing on-device…"
        case let .ready(_, brief): brief.summary
        case .unavailable, nil: nil
        }
    }

    var title: String {
        "\(failure.scriptName) failed with exit code \(failure.exitCode)"
    }

    var overflowText: String? {
        overflowCount > 0 ? "\(overflowCount) more" : nil
    }
}

struct RunScriptFailureBanner: View {
    let presentation: RunScriptFailureBannerPresentation
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        InAppNotificationBanner(
            message: presentation.title + (presentation.overflowText.map { " · " + $0 } ?? ""),
            detail: presentation.detail,
            severity: .error,
            actionTitle: "Show Report",
            action: onOpen,
            dismiss: onDismiss
        )
        .accessibilityIdentifier("run-script-failure-banner")
    }
}
