import Foundation

/// Decides which transcript rows are drawn by `ACPTranscriptCoreTextRowView`
/// instead of a SwiftUI host, and maps them to its content.
///
/// On by default; set `ALAS_TRANSCRIPT_CORETEXT=0` to opt out and draw every
/// row with SwiftUI. Native rows cover finished agent messages (including
/// commentary), collapsed thoughts and tool calls, tool-group headers without
/// hidden members, and plain user messages; their markdown may hold tables of
/// up to `ACPTranscriptMarkdownLayout.maxNativeTableColumns` (5) columns.
/// Everything else stays SwiftUI per row: live/streaming rows, expanded cards,
/// user messages with chips or attachments, tables wider than 5 columns,
/// images, task lists, Mermaid, file edits, plans, notices, visual aids,
/// subagents, and compaction/background tasks.
@MainActor
enum ACPTranscriptNativeRows {
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["ALAS_TRANSCRIPT_CORETEXT"] != "0"

    private static let supportCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 4096
        // Steered streaming checks every growing prefix; bound the keys' bytes.
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    /// Whether `text` could render a chip: a slash command, an absolute
    /// path, a `#12`/`!34` reference, a `~/` path or a URL. The real detectors
    /// need the code host and the file system, so this rejects conservatively.
    private static func mayHoldChips(_ text: String) -> Bool {
        text.hasPrefix("/")
            // Absolute paths after whitespace or any opener, as
            // `ACPAbsolutePathDetector` accepts them; "and/or" stays native.
            || text.range(of: #"(^|[^A-Za-z0-9])/[^\s/]"#, options: .regularExpression) != nil
            || text.range(of: #"[#!]\d"#, options: .regularExpression) != nil
            || text.contains("~/") || text.contains("://")
    }

    /// Parsing is the expensive part and specs rebuild on every publish, so
    /// each source string is parsed once.
    static func supportsMarkdown(_ source: String) -> Bool {
        let key = source as NSString
        if let cached = supportCache.object(forKey: key) { return cached.boolValue }
        let supported = ACPTranscriptMarkdownLayout.supports(ACPMarkdownParser.parse(source))
        supportCache.setObject(NSNumber(value: supported), forKey: key, cost: source.utf8.count)
        return supported
    }

    /// Whether `source` has been parsed for eligibility. Tests use it to pin
    /// that rows which can never be native skip the parse.
    static func hasParsed(_ source: String) -> Bool {
        supportCache.object(forKey: source as NSString) != nil
    }

    /// The native content for `message`, or nil when it must stay SwiftUI.
    /// `isLive` is the live narration flag; tool calls decide liveness from
    /// their own status. `isExpanded` marks a tool call or thought the user
    /// opened, which only the SwiftUI card can show.
    static func content(
        for message: ACPMessage,
        isLive: Bool,
        isCommentary: Bool,
        isExpanded: Bool = false,
        createdAt: Date? = nil
    ) -> ACPTranscriptCoreTextRowView.Content? {
        guard !isLive else { return nil }
        switch message {
        case .user(_, _, let text, let attachments, let delegatedSource, let pastedSpans):
            // Chips are found in the rendered text (entities decoded, `&#35;12`
            // becomes `#12`), so the source and the rendering are both checked.
            guard attachments.isEmpty, pastedSpans.isEmpty, delegatedSource == nil,
                  !mayHoldChips(text), !mayHoldChips(ACPMarkdownInlineRenderer.plainText(text)),
                  supportsMarkdown(text)
            else { return nil }
            return .user(markdown: text)
        case .agent(_, _, let buffer):
            let markdown = buffer.value
            guard supportsMarkdown(markdown) else { return nil }
            return .agent(markdown: markdown, commentary: isCommentary)
        case .thought(_, _, let buffer):
            guard !isExpanded else { return nil }
            return .thought(label: ACPThoughtView.inlineLabel(for: buffer.value) ?? "Thinking…")
        case .toolCall(let call):
            guard !isExpanded, call.status == "completed" || call.status == "failed",
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
                timestamp: createdAt.map { ACPMessageTimestampFormatter.string(for: $0) },
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
        /// Expands a tool call or thought, or toggles a tool-call group
        /// header; nil elsewhere.
        var toggleExpanded: ((Bool) -> Void)?
        var openURL: (URL) -> Void
        /// VoiceOver or Full Keyboard Access is on, so the actions affordance
        /// stays visible instead of appearing on hover.
        var showsActionsPermanently: Bool
        /// Rebuilds the row specs on a later main-actor turn, for a row whose
        /// content can no longer be drawn natively.
        var requestRespec: @MainActor () -> Void = {}

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
        actions: Actions,
        source: StreamingText? = nil
    ) -> ACPTranscriptNativeRow {
        // Read with the content, which the view may mount later.
        let followed = source.map { (text: $0, revision: $0.revision) }
        return ACPTranscriptNativeRow(
            make: { ACPTranscriptCoreTextRowView(frame: .zero) },
            configure: { view in
                (view as? ACPTranscriptCoreTextRowView)?.configure(
                    content: content,
                    contentMaxWidth: contentMaxWidth,
                    inToolCallGroup: inToolCallGroup,
                    theme: theme,
                    typography: typography,
                    actions: actions,
                    source: followed
                )
            }
        )
    }
}
