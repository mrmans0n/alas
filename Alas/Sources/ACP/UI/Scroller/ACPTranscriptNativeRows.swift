import Foundation

/// Decides which transcript rows are drawn by `ACPTranscriptCoreTextRowView`
/// instead of a SwiftUI host, and maps them to its content. Behind
/// `ALAS_TRANSCRIPT_CORETEXT=1`; everything the native view can't draw
/// (selection, chips, expanded cards, live streaming) stays SwiftUI.
@MainActor
enum ACPTranscriptNativeRows {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["ALAS_TRANSCRIPT_CORETEXT"] == "1"

    /// The native content for `message`, or nil when it must stay SwiftUI.
    /// `isLive` is the live narration flag; tool calls decide liveness from
    /// their own status.
    static func content(
        for message: ACPMessage,
        isLive: Bool,
        isCommentary: Bool
    ) -> ACPTranscriptCoreTextRowView.Content? {
        guard !isLive else { return nil }
        switch message {
        case .user(_, _, let text, let attachments, let delegatedSource, let pastedSpans):
            guard attachments.isEmpty, pastedSpans.isEmpty, delegatedSource == nil,
                  !text.hasPrefix("/"),
                  text.range(of: #"(^|\s)/[A-Za-z]"#, options: .regularExpression) == nil,
                  text.range(of: #"#\d"#, options: .regularExpression) == nil,
                  ACPTranscriptMarkdownLayout.supports(ACPMarkdownParser.parse(text))
            else { return nil }
            return .user(markdown: text)
        case .agent(_, _, let buffer):
            let markdown = buffer.value
            guard ACPTranscriptMarkdownLayout.supports(ACPMarkdownParser.parse(markdown)) else { return nil }
            return .agent(markdown: markdown, commentary: isCommentary)
        case .thought(_, _, let buffer):
            return .thought(label: ACPThoughtView.inlineLabel(for: buffer.value) ?? "Thinking…")
        case .toolCall(let call):
            guard call.status == "completed" || call.status == "failed",
                  call.assets.isEmpty, call.terminalIds.isEmpty,
                  ACPContextCompaction(toolCall: call) == nil,
                  ACPBackgroundTask(toolCall: call) == nil,
                  ACPSubagentRowDescriptor(toolCall: call) == nil
            else { return nil }
            let presentation = ACPToolCallPresentation.resolve(call)
            return .toolCall(
                presentation: presentation,
                target: ACPToolCallPresentation.target(for: call, label: presentation.label),
                duration: call.executionDuration.map { ACPToolCallDurationFormatter.string(for: $0) },
                failed: call.status == "failed"
            )
        case .fileEdit, .plan, .systemNotice, .visualAid:
            return nil
        }
    }

    static func row(
        _ content: ACPTranscriptCoreTextRowView.Content,
        contentMaxWidth: CGFloat,
        inToolCallGroup: Bool,
        theme: Theme,
        typography: ACPChatTypography
    ) -> ACPTranscriptNativeRow {
        ACPTranscriptNativeRow(
            make: { ACPTranscriptCoreTextRowView(frame: .zero) },
            configure: { view in
                (view as? ACPTranscriptCoreTextRowView)?.configure(
                    content: content,
                    contentMaxWidth: contentMaxWidth,
                    inToolCallGroup: inToolCallGroup,
                    theme: theme,
                    typography: typography
                )
            }
        )
    }
}
