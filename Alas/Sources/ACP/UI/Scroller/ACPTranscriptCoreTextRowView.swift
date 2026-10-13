import AppKit
import Combine
import CoreText

/// A common transcript row drawn with CoreText in one view instead of a
/// SwiftUI host: agent prose, commentary, a collapsed thought, a collapsed
/// tool call, a tool-call group header, and the user bubble. Hover reveals
/// the message actions button and a tool row's timestamp; clicking a tool
/// row, thought, or group header expands it. Agent and user text can be
/// selected and copied, and code blocks have a "Copy" button. Text rows expose
/// one text-area element; the one-line rows are buttons that expand.
@MainActor
final class ACPTranscriptCoreTextRowView: NSView, ACPTranscriptRowView {
    enum Content: Equatable, Sendable {
        /// Agent markdown; `commentary` adds the narration lane and "Working…" header.
        case agent(markdown: String, commentary: Bool)
        /// A collapsed thought.
        case thought(label: String)
        /// A collapsed tool call.
        /// `timestamp` is shown before the duration while the pointer is over the row.
        case toolCall(presentation: ACPToolCallPresentation, target: String?, duration: String?, timestamp: String? = nil, failed: Bool)
        /// A tool-call group header, without the "Show N earlier" button.
        case toolGroupHeader(label: String, iconSystemName: String, expanded: Bool)
        /// The user's prompt in its right-aligned bubble.
        case user(markdown: String)
    }

    // Copied from `wrapRow`, `ACPCommentaryRow`, `ACPThoughtView`,
    // `ACPToolCallCard`, `ACPToolCallGroupHeaderRow`, `ACPToolCallGroupLane`,
    // `UserMessageRow`, and `ACPUserBubbleChrome`.
    static let columnHorizontalPadding: CGFloat = 28
    static let laneBarWidth: CGFloat = 1.5
    static let laneBarVerticalPadding: CGFloat = 2
    static let laneSpacing: CGFloat = 12
    static let groupMemberIndent: CGFloat = 7
    static let narrationFontSize: CGFloat = 11
    static let narrationIconSpacing: CGFloat = 7
    static let narrationHeaderSpacing: CGFloat = 6
    static let iconPointSize: CGFloat = 11
    static let iconFrameWidth: CGFloat = 16
    static let toolSpacing: CGFloat = 8
    static let toolLabelSize: CGFloat = 12
    static let toolTargetSize: CGFloat = 11.5
    static let toolTargetHorizontalPadding: CGFloat = 5
    static let toolTargetVerticalPadding: CGFloat = 1
    static let toolTargetCornerRadius: CGFloat = 4
    static let toolSpacerMinLength: CGFloat = 6
    static let toolDurationSize: CGFloat = 10
    static let toolVerticalPadding: CGFloat = 3
    static let statusPointSize: CGFloat = 9
    static let chevronPointSize: CGFloat = 9
    static let groupHeaderSpacing: CGFloat = 7
    static let bubbleMaxWidthFraction: CGFloat = 0.75
    static let bubbleLeadingMinSpace: CGFloat = 40
    static let bubbleHorizontalPadding: CGFloat = 13
    static let bubbleVerticalPadding: CGFloat = 9
    static let bubbleCornerRadius: CGFloat = 12
    static let bubbleTailCornerRadius: CGFloat = 4
    static let bubbleStrokeWidth: CGFloat = 0.5
    static let bubbleTopAlpha: CGFloat = 0.32
    static let bubbleBottomAlpha: CGFloat = 0.20
    static let bubbleStrokeAlpha: CGFloat = 0.5
    /// Symbols are rendered once at this scale; Retina is the common case.
    static let symbolScale: CGFloat = 2

    var onIntrinsicSizeInvalidated: (() -> Void)?
    private(set) var lastMeasuredWidth: CGFloat?
    private(set) var needsRemeasure = false

    var content: Content?
    var contentMaxWidth: CGFloat = ACPChatLayout.defaultContentMaxWidth
    var inToolCallGroup = false
    var theme: Theme?
    var typography: ACPChatTypography = .default
    /// Interaction closures from the latest configure, kept even when the
    /// content token is unchanged and the layout is reused.
    private(set) var actions: ACPTranscriptNativeRows.Actions = .inert
    var palette: Palette?
    var symbols: [SymbolRole: Symbol] = [:]
    var cachedLayout: Layout?

    // Stored state shared by the extensions in the sibling files.
    var armedHitTarget: HitTarget?
    /// Where the armed press began, to tell a click from a drag.
    var pressOrigin: NSPoint?

    /// The cursor this row last set; cursors are set on moves rather than
    /// through cursor rects, as the diff rows do.
    var pointerCursor = PointerCursor.arrow

    var isSelectingText = false
    var textSelection: TextSelection? {
        didSet {
            guard textSelection != oldValue else { return }
            // Only the lines either selection covers, so a drag does not
            // redraw every tile of a long message on each event.
            let rects = [oldValue, textSelection].compactMap { $0.flatMap(rect(covering:)) }
            guard let first = rects.first else { return }
            invalidateTiles(rects.dropFirst().reduce(first) { $0.union($1) })
        }
    }

    /// The text rows' text area, kept while their text is, so VoiceOver
    /// keeps its place.
    var textElement: ACPTranscriptTextAccessibilityElement?

    /// The code block showing "Copied".
    var copiedCodeBlock: Int? {
        didSet {
            guard copiedCodeBlock != oldValue, let (markdown, origin) = markdown else { return }
            for index in [oldValue, copiedCodeBlock].compactMap({ $0 }) where markdown.codeBlocks.indices.contains(index) {
                let rect = markdown.copyButtonRect(index, copied: true).union(markdown.copyButtonRect(index, copied: false))
                invalidateTiles(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
    }

    /// How long "Copied" shows, as `CodeBlockView`; tests replace it.
    var codeCopyFeedbackWait: @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(1.5)) }
    var codeCopyFeedbackTask: Task<Void, Never>?

    lazy var hover = ACPDelayedHoverVisibility()
    var hoverObservation: AnyCancellable?
    var isHovering = false
    var isHoverVisible = false
    var isPointerCovered = false
    var isMenuOpen = false {
        didSet { if isMenuOpen != oldValue { refreshActionsVisibility() } }
    }
    var actionsButton: ActionsButton?
    var actionsTimestamp: NSTextField?

    var tiles: [Int: CALayer] = [:]
    lazy var tileDelegate = TileDelegate(view: self)

    var observedClipView: NSClipView?
    var clipObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            dropTiles()
            resetHover()
            armedHitTarget = nil
            pressOrigin = nil
            isSelectingText = false
            pointerCursor = .arrow
        } else {
            updateTileScale()
            needsDisplay = true
        }
        observeClipView()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeClipView()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateTileScale()
    }

    // MARK: - Content

    func configure(
        content: Content, contentMaxWidth: CGFloat, inToolCallGroup: Bool, theme: Theme, typography: ACPChatTypography,
        actions: ACPTranscriptNativeRows.Actions = .inert
    ) {
        self.actions = actions
        defer { syncActionsButton() }
        let sizeChanged = content != self.content || contentMaxWidth != self.contentMaxWidth
            || inToolCallGroup != self.inToolCallGroup || typography != self.typography
        guard sizeChanged || theme != self.theme else { return }
        if content != self.content {
            // Offsets into the old text mean nothing in the new.
            textSelection = nil
            codeCopyFeedbackTask?.cancel()
            copiedCodeBlock = nil
            textElement = nil
        }
        self.content = content
        self.contentMaxWidth = contentMaxWidth
        self.inToolCallGroup = inToolCallGroup
        self.theme = theme
        self.typography = typography
        let palette = Palette(theme: theme)
        self.palette = palette
        symbols = Self.renderSymbols(for: content, palette: palette)
        cachedLayout = nil
        invalidateTiles()
        actionsButton?.apply(theme: theme)
        if sizeChanged { onIntrinsicSizeInvalidated?() }
    }

    func markNeedsRemeasure() {
        needsRemeasure = true
    }

    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        needsRemeasure = false
        lastMeasuredWidth = width
        positionActions()
        return layout(forWidth: width).height
    }

    /// The content column, in view coordinates, at `lastMeasuredWidth`.
    var columnRect: CGRect {
        guard let lastMeasuredWidth else { return .zero }
        return layout(forWidth: lastMeasuredWidth).column
    }
}
