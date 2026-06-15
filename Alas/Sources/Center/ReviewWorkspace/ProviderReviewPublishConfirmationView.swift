import SwiftUI

struct ProviderReviewPublishConfirmationView: View {
    let providerName: String
    let reviewIdentity: String
    let commentCount: Int
    let unpublishableMessages: [String]
    @Binding var selectedDecision: ProviderReviewDecision
    let isPublishing: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Publish review")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))

            Text("\(providerName) \(reviewIdentity)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.color("fg-muted"))

            Picker("Decision", selection: $selectedDecision) {
                Text("Comment").tag(ProviderReviewDecision.comment)
                Text("Approve").tag(ProviderReviewDecision.approve)
                Text("Request changes").tag(ProviderReviewDecision.requestChanges)
            }
            .pickerStyle(.segmented)
            .disabled(isPublishing)
            .accessibilityIdentifier("provider-review-publish-decision")

            Text(commentCountText)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))

            if !unpublishableMessages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unable to publish")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.color("warn"))
                    ForEach(unpublishableMessages, id: \.self) { message in
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundColor(theme.color("warn"))
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                DiffReviewAccessibilityMarker(
                                    identifier: "provider-review-publish-unpublishable-\(message.stableAccessibilityIDComponent)",
                                    label: message
                                )
                            )
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.color("warn").opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("del"))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        DiffReviewAccessibilityMarker(
                            identifier: "provider-review-publish-error",
                            label: errorMessage
                        )
                    )
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isPublishing)
                    .accessibilityIdentifier("provider-review-publish-cancel")
                Button(isPublishing ? "Publishing..." : "Publish", action: onConfirm)
                    .disabled(isConfirmDisabled)
                    .keyboardShortcut(.defaultAction)
                    .background(
                        ProviderReviewPublishPressMarker(
                            identifier: "provider-review-publish-confirm",
                            label: "Publish",
                            isEnabled: !isConfirmDisabled,
                            action: onConfirm
                        )
                    )
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.color("line"), lineWidth: 0.75)
        )
        .accessibilityIdentifier("provider-review-publish-confirmation")
        .background(
            DiffReviewAccessibilityMarker(
                identifier: "provider-review-publish-confirmation",
                label: "Publish review \(providerName) \(reviewIdentity), \(commentCountText)"
            )
        )
    }

    private var commentCountText: String {
        "\(commentCount) \(commentCount == 1 ? "comment" : "comments")"
    }

    private var isConfirmDisabled: Bool {
        isPublishing || (commentCount == 0 && selectedDecision == .comment)
    }
}

private struct ProviderReviewPublishPressMarker: NSViewRepresentable {
    let identifier: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> ProviderReviewPublishPressView {
        let view = ProviderReviewPublishPressView(frame: .zero)
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
        return view
    }

    func updateNSView(_ view: ProviderReviewPublishPressView, context: Context) {
        view.setAccessibilityIdentifier(identifier)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.button)
        view.setAccessibilityEnabled(isEnabled)
        view.isEnabled = isEnabled
        view.action = action
    }
}

private final class ProviderReviewPublishPressView: NSView {
    var isEnabled = true
    var action: () -> Void = {}

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action()
        return true
    }
}

private extension String {
    var stableAccessibilityIDComponent: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return unicodeScalars
            .map { allowed.contains($0) ? Character($0).description : "-" }
            .joined()
    }
}
