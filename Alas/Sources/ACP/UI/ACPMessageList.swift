import AppKit
import SwiftUI

struct ACPMessageList: View {
    @ObservedObject var session: ACPSession
    @ObservedObject var transcript: ACPTranscript
    let onOpenDiff: (String) -> Void
    let policy: ACPPermissionPolicy?
    let scopeKey: String
    @Environment(\.theme) private var theme
    @State private var viewportHeight: CGFloat = 0
    @State private var tailFrame: CGRect = .zero
    @State private var isRestoringTail = false
    @State private var userInterruptedTailRestore = false

    /// Height of an invisible spacer at the tail of the VStack. The
    /// composer pill plus its outer padding occupies roughly this much
    /// vertical space, so by scrolling THAT element to the viewport
    /// bottom we guarantee the streaming caret / last message sits
    /// above the composer instead of behind it.
    private let composerSpacerHeight: CGFloat = 220
    private let tailTolerance: CGFloat = 36
    private var scrollSpaceName: String { "acp-message-list-\(session.id)" }

    /// Cheap signature of the entire transcript. SwiftUI re-evaluates when
    /// any cell mutates (e.g. an agent_message_chunk merging into the
    /// trailing message) so the scroll-to-bottom hook fires for streaming
    /// edits in addition to brand-new rows.
    private var scrollSignature: Int {
        var hasher = Hasher()
        hasher.combine(transcript.messages.count)
        if let last = transcript.messages.last {
            hasher.combine(last.kind)
            switch last {
            case .agent(_, let t), .thought(_, let t), .systemNotice(_, let t):
                hasher.combine(t.count)
            case .toolCall(let tc):
                hasher.combine(tc.status)
                hasher.combine(tc.content.count)
            case .fileEdit(_, let e):
                hasher.combine(e.added)
                hasher.combine(e.removed)
            case .plan(_, let items):
                hasher.combine(items.count)
                for it in items { hasher.combine(it.status) }
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
                        ForEach(transcript.messages, id: \.stableId) { message in
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
                        // Invisible tail spacer that the auto-scroll pins to
                        // the viewport bottom; this guarantees the streaming
                        // caret / last message sits above the composer pill.
                        Color.clear
                            .frame(height: composerSpacerHeight)
                            .id("__composer_spacer__")
                            .background(
                                GeometryReader { tail in
                                    Color.clear.preference(
                                        key: ACPTailFramePreferenceKey.self,
                                        value: tail.frame(in: .named(scrollSpaceName))
                                    )
                                }
                            )
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: scrollSpaceName)
                .background(
                    ACPScrollEventObserver { userDriven in
                        updateTailFollowingFromCurrentFrame(userDriven: userDriven)
                    }
                )
                .onAppear {
                    viewportHeight = viewport.size.height
                    restoreTailIfNeeded(proxy: proxy, animated: false)
                }
                .onChange(of: viewport.size.height) { _, height in
                    viewportHeight = height
                    restoreTailIfNeeded(proxy: proxy, animated: false)
                }
                .onPreferenceChange(ACPTailFramePreferenceKey.self) { frame in
                    tailFrame = frame
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
        userInterruptedTailRestore = false
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
            if !userInterruptedTailRestore {
                setFollowsTranscriptTail(true)
            }
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

    private func updateTailFollowingFromCurrentFrame(userDriven: Bool) {
        guard viewportHeight > 0 else { return }
        if isRestoringTail {
            guard userDriven else { return }
            userInterruptedTailRestore = true
            setFollowsTranscriptTail(false)
            return
        }
        setFollowsTranscriptTail(tailFrame.maxY <= viewportHeight + tailTolerance)
    }

    private func setFollowsTranscriptTail(_ follows: Bool) {
        guard session.followsTranscriptTail != follows else { return }
        session.followsTranscriptTail = follows
    }

    @ViewBuilder
    private func row(for m: ACPMessage) -> some View {
        switch m {
        case .user(_, let text, let attachments):
            UserMessageRow(text: text, attachments: attachments)
        case .agent(_, let text):
            AgentMessageRow(text: text)
        case .thought(_, let text):
            ACPThoughtView(text: text)
        case .toolCall(let tc):
            ACPToolCallCard(toolCall: tc)
        case .fileEdit(_, let edit):
            ACPFileEditCard(edit: edit, onOpenDiff: { onOpenDiff(edit.path) })
        case .plan(_, let items):
            ACPPlanCard(items: items)
        case .systemNotice(_, let text):
            ACPSystemNoticeView(text: text)
        }
    }
}

private struct ACPTailFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ACPScrollEventObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = { scrollView in
            context.coordinator.observe(scrollView: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        context.coordinator.onScroll = onScroll
        nsView.resolve()
    }

    @MainActor
    final class Coordinator {
        var onScroll: (Bool) -> Void
        private weak var observedScrollView: NSScrollView?
        private var observer: NSObjectProtocol?

        init(onScroll: @escaping (Bool) -> Void) {
            self.onScroll = onScroll
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observe(scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else { return }
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                let userDriven = Self.isUserDrivenScrollEvent
                Task { @MainActor in
                    self?.onScroll(userDriven)
                }
            }
        }

        private static var isUserDrivenScrollEvent: Bool {
            guard let event = NSApp.currentEvent else { return false }
            switch event.type {
            case .scrollWheel, .leftMouseDragged, .gesture, .magnify, .swipe:
                return true
            default:
                return false
            }
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

// MARK: - User bubble (right-aligned)

private struct UserMessageRow: View {
    let text: String
    let attachments: [ACPMessage.Attachment]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                if !attachments.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(attachments, id: \.uri) { a in
                            FileChip(path: a.name ?? a.uri, lines: nil, iconSystemName: "at")
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
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Agent prose (markdown-rendered, full-width)

private struct AgentMessageRow: View {
    let text: String
    var body: some View {
        ACPMarkdownText(raw: text)
            .frame(maxWidth: .infinity, alignment: .leading)
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
