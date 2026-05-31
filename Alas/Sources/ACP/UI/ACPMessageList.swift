import AppKit
import SwiftUI

struct ACPMessageList: View {
    @ObservedObject var session: ACPSession
    @ObservedObject var transcript: ACPTranscript
    let onOpenDiff: (String) -> Void
    let policy: ACPPermissionPolicy?
    let scopeKey: String
    /// Callbacks invoked by the pending bubbles + header. The host wires
    /// these to the runner.
    let onQueueEdit: (QueuedPrompt) -> Void
    let onQueueRemove: (UUID) -> Void
    let onQueueRetry: (UUID) -> Void
    let onQueueReorder: (Int, Int) -> Void
    let onQueueClearAll: () -> Void
    /// Resolves the full persisted content of a tool call by id when an
    /// expanded card's in-memory content was truncated. Wired by the host
    /// to `ACPSessionManager.reloadFullToolCallContent`. Returns nil when
    /// the row is gone or the payload is undecodable.
    let onLoadFullToolCallContent: (String) -> String?
    @Environment(\.theme) private var theme
    @State private var isRestoringTail = false
    @State private var headFrame: CGRect = .zero
    @State private var lastHeadStepAt: Date = .distantPast
    @State private var scrollViewRef = ACPWeakScrollViewRef()

    /// Height of an invisible spacer at the tail of the VStack. The
    /// composer pill plus its outer padding occupies roughly this much
    /// vertical space, so by scrolling THAT element to the viewport
    /// bottom we guarantee the streaming caret / last message sits
    /// above the composer instead of behind it.
    private let composerSpacerHeight: CGFloat = 220
    /// Step the visible head back when the "Earlier messages…" marker
    /// crosses this many points from the top edge during scroll.
    private let headStepScrollThreshold: CGFloat = 200
    /// Minimum gap between automatic head-back steps so a single scroll
    /// doesn't decrement multiple times before layout settles.
    private let headStepDebounceInterval: TimeInterval = 0.3
    private var scrollSpaceName: String { "acp-message-list-\(session.id)" }

    /// Window-sliced, plan-filtered list of rows to render. The slice
    /// bounds first-paint cost on long transcripts (`visibleHead` is
    /// reset to `max(0, count - tailWindow)` after hydration); the
    /// filter drops `.plan` entries because the toolbar pill renders
    /// the current turn's plan instead of an inline card.
    private var visibleMessages: [ACPMessage] {
        let head = min(transcript.visibleHead, transcript.messages.count)
        return transcript.messages[head...].filter {
            if case .plan = $0 { return false }
            return true
        }
    }

    /// Cheap signature of the entire transcript. SwiftUI re-evaluates when
    /// any cell mutates (e.g. an agent_message_chunk merging into the
    /// trailing message) so the scroll-to-bottom hook fires for streaming
    /// edits in addition to brand-new rows.
    private var scrollSignature: Int {
        var hasher = Hasher()
        hasher.combine(transcript.messages.count)
        hasher.combine(session.queue.count)
        hasher.combine(session.queue.first?.status)
        // Streaming chunks mutate the buffer in place without re-publishing
        // the transcript array; the tick gives the body a reason to re-eval
        // so this signature changes and the tail-scroll fires per chunk.
        hasher.combine(transcript.streamingTick)
        if let last = transcript.messages.last {
            hasher.combine(last.kind)
            switch last {
            case .agent(_, let buf), .thought(_, let buf):
                hasher.combine(buf.value.count)
            case .systemNotice(_, let t):
                hasher.combine(t.count)
            case .toolCall(let tc):
                hasher.combine(tc.status)
                hasher.combine(tc.content.count)
            case .fileEdit(_, let e):
                hasher.combine(e.added)
                hasher.combine(e.removed)
            case .plan:
                break
            case .user(_, let t, _):
                hasher.combine(t.count)
            }
        }
        return hasher.finalize()
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if transcript.visibleHead > 0 {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.bottom, 4)
                                .background(
                                    GeometryReader { headGeom in
                                        Color.clear.preference(
                                            key: ACPHeadFramePreferenceKey.self,
                                            value: headGeom.frame(in: .named(scrollSpaceName))
                                        )
                                    }
                                )
                        }
                        ForEach(visibleMessages, id: \.stableId) { message in
                            row(for: message)
                        }
                        if transcript.pendingPermission != nil, let policy = policy {
                            ACPPermissionPrompt(session: session, policy: policy, scopeKey: scopeKey)
                                .id("__pending_perm__")
                        }
                        if transcript.streamingState == .streaming {
                            StreamingCaret().frame(width: 8, height: 14)
                                .id("__streaming_caret__")
                        }
                        if session.visibleQueueCount > 1 {
                            ACPQueueHeader(count: session.visibleQueueCount, onClear: onQueueClearAll)
                                .id("__queue_header__")
                        }
                        ForEach(Array(session.queue.enumerated()), id: \.element.id) { idx, item in
                            if item.status != .sending {
                                ACPQueuedBubble(
                                    item: item,
                                    onEdit: { onQueueEdit(item) },
                                    onRemove: { onQueueRemove(item.id) },
                                    onRetry: { onQueueRetry(item.id) }
                                )
                                .dropDestination(for: String.self) { items, _ in
                                    guard let s = items.first,
                                          let uuid = UUID(uuidString: s),
                                          let src = session.queue.firstIndex(where: { $0.id == uuid })
                                    else { return false }
                                    onQueueReorder(src, idx)
                                    return true
                                }
                                .id("__queue_\(item.id)")
                            }
                        }
                        // Invisible tail spacer that the auto-scroll pins to
                        // the viewport bottom; this guarantees the streaming
                        // caret / last message sits above the composer pill.
                        Color.clear
                            .frame(height: composerSpacerHeight)
                            .id("__composer_spacer__")
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: scrollSpaceName)
                .background(
                    ACPScrollEventObserver(
                        onPaused: {
                            setFollowsTranscriptTail(false)
                        },
                        onAtBottom: {
                            setFollowsTranscriptTail(true)
                        },
                        isRestoring: { isRestoringTail },
                        onScrollViewResolved: { scrollViewRef.scrollView = $0 }
                    )
                )
                .onAppear {
                    restoreTailIfNeeded(proxy: proxy, animated: false)
                }
                .onChange(of: viewport.size.height) { _, _ in
                    restoreTailIfNeeded(proxy: proxy, animated: false)
                }
                .onPreferenceChange(ACPHeadFramePreferenceKey.self) { frame in
                    headFrame = frame
                    // Auto-paginate: step back when the sentinel enters the
                    // threshold band at the top of the viewport; debounce so
                    // a single scroll doesn't decrement multiple times before
                    // SwiftUI lays out the newly-revealed rows.
                    // `frame.maxY > 0` ensures the sentinel is actually
                    // visible — without it, restoring to the tail of a
                    // long transcript puts the sentinel far above the
                    // viewport (negative minY *and* negative maxY) and the
                    // initial preference fire would still satisfy
                    // `minY < threshold`, defeating the window before the
                    // user scrolled.
                    guard transcript.visibleHead > 0 else { return }
                    guard frame.minY < headStepScrollThreshold, frame.maxY > 0 else { return }
                    let now = Date()
                    guard now.timeIntervalSince(lastHeadStepAt) > headStepDebounceInterval else { return }
                    lastHeadStepAt = now
                    stepHeadBackPreservingScroll()
                }
                .onChange(of: scrollSignature) { _, _ in
                    if session.followsTranscriptTail {
                        scrollToTail(proxy: proxy, animated: true)
                    }
                }
                .onChange(of: transcript.streamingState) { _, new in
                    if session.followsTranscriptTail && (new == .streaming || new == .sending) {
                        scrollToTail(proxy: proxy, animated: true)
                    }
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

    private func restoreTailIfNeeded(proxy: ScrollViewProxy, animated: Bool) {
        guard session.followsTranscriptTail else { return }
        scrollToTail(proxy: proxy, animated: animated)
    }

    private func scrollToTail(proxy: ScrollViewProxy, animated: Bool) {
        isRestoringTail = true
        let scroll = {
            proxy.scrollTo("__composer_spacer__", anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.12)) {
                scroll()
            }
        } else {
            scroll()
        }
        let releaseRestoring = {
            isRestoringTail = false
        }
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                releaseRestoring()
            }
        } else {
            DispatchQueue.main.async {
                releaseRestoring()
            }
        }
    }

    private func setFollowsTranscriptTail(_ follows: Bool) {
        guard session.followsTranscriptTail != follows else { return }
        session.followsTranscriptTail = follows
    }

    /// Reveal older messages while keeping the viewport anchored to the
    /// same content. Captures the content height before `stepHeadBack()`
    /// prepends rows, then adjusts the clip-view origin by the delta so
    /// the user's reading position doesn't jump.
    private func stepHeadBackPreservingScroll() {
        guard let scrollView = scrollViewRef.scrollView else {
            transcript.stepHeadBack()
            return
        }
        let clipView = scrollView.contentView
        let oldOffset = clipView.bounds.origin.y
        let oldContentHeight = scrollView.documentView?.bounds.height ?? 0

        isRestoringTail = true
        transcript.stepHeadBack()

        // After SwiftUI lays out the prepended rows, compute the content
        // height delta and shift the clip-view origin so the viewport
        // stays anchored to the same messages.
        DispatchQueue.main.async {
            let newContentHeight = scrollView.documentView?.bounds.height ?? 0
            let delta = newContentHeight - oldContentHeight
            if delta > 0 {
                clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: oldOffset + delta))
            }
            DispatchQueue.main.async {
                isRestoringTail = false
            }
        }
    }

    @ViewBuilder
    private func row(for m: ACPMessage) -> some View {
        switch m {
        case .user(_, let text, let attachments):
            UserMessageRow(text: text, attachments: attachments)
        case .agent(let id, let buf):
            AgentMessageRow(messageId: id.uuidString, transcript: transcript, buffer: buf)
        case .thought(_, let buf):
            ACPThoughtView(buffer: buf)
        case .toolCall(let tc):
            ACPToolCallCard(
                toolCall: tc,
                loadFullContent: tc.isContentTruncated
                    ? { [tcid = tc.toolCallId] in onLoadFullToolCallContent(tcid) }
                    : nil)
                .environment(\.acpTerminalHost, session.terminalHost)
        case .fileEdit(_, let edit):
            ACPFileEditCard(edit: edit, onOpenDiff: { onOpenDiff(edit.path) })
        case .plan:
            EmptyView()
        case .systemNotice(_, let text):
            ACPSystemNoticeView(text: text)
        }
    }
}

private final class ACPWeakScrollViewRef {
    weak var scrollView: NSScrollView?
}

private struct ACPHeadFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ACPScrollEventObserver: NSViewRepresentable {
    let onPaused: () -> Void
    let onAtBottom: () -> Void
    let isRestoring: () -> Bool
    var onScrollViewResolved: ((NSScrollView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaused: onPaused, onAtBottom: onAtBottom, isRestoring: isRestoring)
    }

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = { scrollView in
            context.coordinator.observe(scrollView: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        context.coordinator.onPaused = onPaused
        context.coordinator.onAtBottom = onAtBottom
        context.coordinator.isRestoring = isRestoring
        context.coordinator.onScrollViewResolved = onScrollViewResolved
        nsView.resolve()
    }

    @MainActor
    final class Coordinator {
        var onPaused: () -> Void
        var onAtBottom: () -> Void
        var isRestoring: () -> Bool
        var onScrollViewResolved: ((NSScrollView) -> Void)?
        private weak var observedScrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var lastOffsetY: CGFloat?

        init(onPaused: @escaping () -> Void,
             onAtBottom: @escaping () -> Void,
             isRestoring: @escaping () -> Bool) {
            self.onPaused = onPaused
            self.onAtBottom = onAtBottom
            self.isRestoring = isRestoring
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observe(scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else {
                onScrollViewResolved?(scrollView)
                return
            }
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observedScrollView = scrollView
            onScrollViewResolved?(scrollView)
            lastOffsetY = scrollView.contentView.bounds.origin.y
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                // queue: .main delivers on the main thread; assume MainActor
                // isolation rather than hopping through a Task so the decision
                // lands before the next streaming chunk fires scrollToTail.
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.handleBoundsChange(scrollView)
                }
            }
        }

        private func handleBoundsChange(_ scrollView: NSScrollView) {
            let cv = scrollView.contentView
            let newY = cv.bounds.origin.y
            let viewportH = cv.bounds.height
            let contentH = scrollView.documentView?.bounds.height ?? 0
            let decision = ACPScrollDirectionClassifier.decide(
                previousOffsetY: lastOffsetY,
                newOffsetY: newY,
                viewportHeight: viewportH,
                contentHeight: contentH,
                isRestoring: isRestoring(),
                isUserDriven: Self.isUserDrivenScrollEvent
            )
            lastOffsetY = newY
            switch decision {
            case .userScrolledUp: onPaused()
            case .userAtBottom: onAtBottom()
            case .noChange: break
            }
        }

        private static var isUserDrivenScrollEvent: Bool {
            ACPUserScrollEvent.isUserDriven(NSApp.currentEvent?.type)
        }
    }

    final class ResolverView: NSView {
        var onResolve: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? NSScrollView {
                        self.onResolve?(scrollView)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

/// Maps an `NSEvent.EventType` to whether it represents a live user scroll
/// gesture, used by `ACPScrollEventObserver` to decide if an upward bounds
/// change is deliberate. Extracted as a pure function so the mapping is unit
/// testable without a running event loop.
///
/// The set is deliberately narrow. `NSApp.currentEvent` reports the most
/// recent app-wide event, not the cause of the bounds change, so any event
/// type that also occurs away from scrolling would misattribute layout reflow
/// during streaming and re-latch the false pause this guards against:
///   - `.keyDown`: the transcript `ScrollView` never holds key focus here (the
///     composer owns it), so keyboard paging can't scroll it; accepting it
///     would catch composer typing during streaming.
///   - `.leftMouseDown` / `.leftMouseUp`: a bare click can't be told apart from
///     clicking a transcript control (expanding a card, the copy button) by
///     type alone, so it would catch reflow that coincides with such a click.
/// The covered cases (trackpad and dragging the scroller knob) only fire while
/// actually scrolling, so they can't be confused with idle layout reflow.
enum ACPUserScrollEvent {
    static func isUserDriven(_ type: NSEvent.EventType?) -> Bool {
        guard let type else { return false }
        switch type {
        case .scrollWheel, .leftMouseDragged, .gesture, .magnify, .swipe:
            return true
        default:
            return false
        }
    }
}

// MARK: - Hover copy button

/// Hover-revealed affordance that copies a message's raw Markdown to the
/// pasteboard as plain text. The caller passes exactly the text
/// `ACPTranscriptMarkdown.messageBody` would return for this row.
private struct ACPHoverCopyButton: View {
    let markdown: String
    var onHoverChange: ((Bool) -> Void)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(markdown, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-muted"))
                .padding(4)
                .background(theme.color("bg-3").opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { onHoverChange?($0) }
        .help("Copy message as Markdown")
    }
}

@MainActor
final class ACPDelayedHoverVisibility: ObservableObject {
    @Published private(set) var isVisible = false

    private let hideDelayNanoseconds: UInt64
    private var hideTask: Task<Void, Never>?

    init(hideDelayNanoseconds: UInt64 = 350_000_000) {
        self.hideDelayNanoseconds = hideDelayNanoseconds
    }

    deinit {
        hideTask?.cancel()
    }

    func enter() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = true
    }

    func leave() {
        hideTask?.cancel()
        let delay = hideDelayNanoseconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.isVisible = false
                self?.hideTask = nil
            }
        }
    }
}

// MARK: - User bubble (right-aligned)

private struct UserMessageRow: View {
    let text: String
    let attachments: [ACPMessage.Attachment]
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                if !attachments.isEmpty {
                    let images = attachments.filter { ($0.mimeType?.hasPrefix("image/")) == true }
                    let others = attachments.filter { ($0.mimeType?.hasPrefix("image/")) != true }
                    if !images.isEmpty {
                        HStack(spacing: 6) {
                            // Key by index, not uri: content-addressed staging
                            // means the same image attached twice shares a uri,
                            // and duplicate ForEach ids collapse the row.
                            ForEach(Array(images.enumerated()), id: \.offset) { _, a in
                                if let url = URL(string: a.uri) {
                                    ACPImageThumbnail(fileURL: url)
                                }
                            }
                        }
                    }
                    if !others.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(others, id: \.uri) { a in
                                FileChip(path: a.name ?? a.uri, lines: nil, iconSystemName: "at")
                            }
                        }
                    }
                }
                ACPMarkdownText(raw: text)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 13)
                    .background(
                        LinearGradient(
                            colors: [
                                theme.color("accent").opacity(0.32),
                                theme.color("accent").opacity(0.20)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .clipShape(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12)
                        )
                    )
                    .overlay(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12)
                        )
                        .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            }
            .frame(maxWidth: 540, alignment: .trailing)
            .overlay(alignment: .topLeading) {
                if hovering {
                    ACPHoverCopyButton(markdown: text).offset(x: -6, y: -6)
                }
            }
            .onHover { hovering = $0 }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Agent prose (markdown-rendered, full-width)

private struct AgentMessageRow: View {
    let messageId: String
    let transcript: ACPTranscript
    @ObservedObject var buffer: StreamingText
    @StateObject private var hoverVisibility = ACPDelayedHoverVisibility()
    var body: some View {
        ACPMarkdownText(raw: buffer.value, cache: transcript.markdownCache(forMessage: messageId))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                if hoverVisibility.isVisible {
                    ACPHoverCopyButton(markdown: buffer.value) { hovering in
                        if hovering {
                            hoverVisibility.enter()
                        } else {
                            hoverVisibility.leave()
                        }
                    }
                    .offset(x: -2, y: -6)
                }
            }
            .onHover { hovering in
                if hovering {
                    hoverVisibility.enter()
                } else {
                    hoverVisibility.leave()
                }
            }
    }
}

// MARK: - Streaming caret

private struct StreamingCaret: View {
    @State private var on = false
    @Environment(\.theme) private var theme
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(theme.color("accent"))
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
