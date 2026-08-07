import AppKit
import SwiftUI

struct ACPMessageList: View {
    @ObservedObject var session: ACPSession
    @ObservedObject var transcript: ACPTranscript
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let onOpenDiff: (String) -> Void
    let onOpenTranscriptLink: (URL) -> Bool
    let policy: ACPPermissionPolicy?
    let trustedImageRoot: URL?
    let scopeKey: String
    let onUserInputResponse: (UUID, ACPUserInputAction) -> Void
    let onOpenElicitationURL: (UUID) async -> Bool
    let onDismissElicitationURLWait: (String) -> Void
    /// Callbacks invoked by the pending bubbles + header. The host wires
    /// these to the runner.
    let onQueueEdit: (QueuedPrompt) -> Void
    let onQueueForceSend: (UUID) -> Void
    let onQueueRemove: (UUID) -> Void
    let onQueueRetry: (UUID) -> Void
    let onQueueReorder: (Int, Int) -> Void
    let onQueueClearAll: () -> Void
    let onRetryContextRecovery: () -> Void
    let rememberedScrollAnchor: () -> String?
    let onRememberScrollAnchor: (String?, Int?, Bool) -> Void
    /// Resolves the full persisted content of a tool call by id when an
    /// expanded card's in-memory content was truncated. Wired by the host
    /// to `ACPSessionManager.reloadFullToolCallContent`. Returns nil when
    /// the row is gone or the payload is undecodable.
    let onLoadFullToolCallContent: (String) async -> String?
    let forkTargets: [ACPSessionForkTarget]
    let onFork: (ACPForkMessageBoundary, String) -> Void
    let onOpenForkSource: (String) -> Void
    let agentDisplayName: (String) -> String
    @Environment(\.theme) private var theme

    /// Height of an invisible spacer at the tail of the transcript stack. The
    /// composer pill plus its outer padding occupies roughly this much
    /// vertical space, so by scrolling THAT element to the viewport
    /// bottom we guarantee the streaming caret / last message sits
    /// above the composer instead of behind it.
    private let composerSpacerHeight: CGFloat = 220
    private let goToNewestButtonSize: CGFloat = 32
    private let goToNewestButtonComposerGap: CGFloat = 12

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ACPTranscriptScroller(
                session: session,
                transcript: transcript,
                contentMaxWidth: contentMaxWidth,
                typography: typography,
                trustedImageRoot: trustedImageRoot,
                onOpenDiff: onOpenDiff,
                onLoadFullToolCallContent: onLoadFullToolCallContent,
                forkTargets: forkTargets,
                onFork: onFork,
                rememberedScrollAnchor: rememberedScrollAnchor,
                onRememberScrollAnchor: onRememberScrollAnchor,
                onOpenTranscriptLink: onOpenTranscriptLink,
                policy: policy,
                scopeKey: scopeKey,
                onUserInputResponse: onUserInputResponse,
                onOpenElicitationURL: onOpenElicitationURL,
                onDismissElicitationURLWait: onDismissElicitationURLWait,
                onQueueEdit: onQueueEdit,
                onQueueForceSend: onQueueForceSend,
                onQueueRemove: onQueueRemove,
                onQueueRetry: onQueueRetry,
                onQueueReorder: onQueueReorder,
                onQueueClearAll: onQueueClearAll,
                onRetryContextRecovery: onRetryContextRecovery,
                onOpenForkSource: onOpenForkSource,
                agentDisplayName: agentDisplayName
            )
            if Self.shouldShowGoToNewestAffordance(
                followsTranscriptTail: session.followsTranscriptTail
            ) {
                goToNewestButton {
                    session.followsTranscriptTail = true
                    transcript.resetWindowToTail()
                    onRememberScrollAnchor(nil, nil, true)
                }
            }
        }
        .background(
            LinearGradient(
                colors: [theme.color("bg-1"), theme.color("bg-0")],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func goToNewestButton(action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: goToNewestButtonSize, height: goToNewestButtonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("fg"))
        .background(
            Circle()
                .fill(theme.color("bg-1").opacity(0.95))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .overlay(
            Circle()
                .strokeBorder(theme.color("line").opacity(0.9), lineWidth: 0.5)
        )
        .accessibilityLabel("Go to newest message")
        .help("Go to newest message")
        .padding(.trailing, 20)
        .padding(.bottom, Self.goToNewestAffordanceBottomPadding(
            composerSpacerHeight: composerSpacerHeight,
            gap: goToNewestButtonComposerGap
        ))
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    nonisolated static func shouldShowGoToNewestAffordance(
        followsTranscriptTail: Bool
    ) -> Bool {
        !followsTranscriptTail
    }

    nonisolated static func goToNewestAffordanceBottomPadding(
        composerSpacerHeight: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        composerSpacerHeight + gap
    }
}
