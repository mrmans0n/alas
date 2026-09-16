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

struct RunScriptFailureBanner: View {
    let presentation: RunScriptFailureBannerPresentation
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        InAppNotificationBanner(
            message: presentation.title + (presentation.overflowText.map { " · " + $0 } ?? ""),
            severity: .error,
            actionTitle: "Show Report",
            action: onOpen,
            dismiss: onDismiss
        )
        .accessibilityIdentifier("run-script-failure-banner")
    }
}
