import Foundation

/// Decides which transcript rows are drawn by `ACPTranscriptCoreTextRowView`
/// instead of a SwiftUI host, and maps them to its content. Behind
/// `ALAS_TRANSCRIPT_CORETEXT=1`; everything the native view can't draw
/// (selection, chips, expanded cards, live streaming) stays SwiftUI.
@MainActor
enum ACPTranscriptNativeRows {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["ALAS_TRANSCRIPT_CORETEXT"] == "1"

    private static let supportCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 4096
        return cache
    }()

    /// Parsing is the expensive part and specs rebuild on every publish, so
    /// each source string is parsed once.
    private static func supportsMarkdown(_ source: String) -> Bool {
        let key = source as NSString
        if let cached = supportCache.object(forKey: key) { return cached.boolValue }
        let supported = ACPTranscriptMarkdownLayout.supports(ACPMarkdownParser.parse(source))
        supportCache.setObject(NSNumber(value: supported), forKey: key)
        return supported
    }

    /// Whether `source` has been parsed for eligibility. Tests use it to pin
    /// that rows which can never be native skip the parse.
    static func hasParsed(_ source: String) -> Bool {
        supportCache.object(forKey: source as NSString) != nil
    }

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
                  supportsMarkdown(text)
            else { return nil }
            return .user(markdown: text)
        case .agent(_, _, let buffer):
            let markdown = buffer.value
            guard supportsMarkdown(markdown) else { return nil }
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

    /// What a native row can do beyond drawing. Stored on the view rather than
    /// folded into `Content`, so a row whose token is unchanged keeps the
    /// closures it was last configured with, as the SwiftUI rows do.
    struct Actions {
        /// The "…" menu inputs; nil for rows without a gutter (thoughts, tool
        /// calls, group headers).
        var menu: ACPMessageActionsMenu.Input?
        /// Toggles a tool-call group header; nil elsewhere.
        var toggleExpanded: ((Bool) -> Void)?
        var openURL: (URL) -> Void
        /// VoiceOver or Full Keyboard Access is on, so the actions affordance
        /// stays visible instead of appearing on hover.
        var showsActionsPermanently: Bool

        static var inert: Actions {
            Actions(menu: nil, toggleExpanded: nil, openURL: { _ in }, showsActionsPermanently: false)
        }
    }

    static func row(
        _ content: ACPTranscriptCoreTextRowView.Content,
        contentMaxWidth: CGFloat,
        inToolCallGroup: Bool,
        theme: Theme,
        typography: ACPChatTypography,
        actions: Actions
    ) -> ACPTranscriptNativeRow {
        ACPTranscriptNativeRow(
            make: { ACPTranscriptCoreTextRowView(frame: .zero) },
            configure: { view in
                (view as? ACPTranscriptCoreTextRowView)?.configure(
                    content: content,
                    contentMaxWidth: contentMaxWidth,
                    inToolCallGroup: inToolCallGroup,
                    theme: theme,
                    typography: typography,
                    actions: actions
                )
            }
        )
    }
}
