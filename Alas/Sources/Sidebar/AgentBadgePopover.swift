import AlasCore
import AppKit
import SwiftUI

/// The hover card of a sidebar agent badge: who, what state, the one line
/// that matters for that state, and the model and context underneath. What
/// it says is decided by `AgentBadgePopoverModel`.
struct AgentBadgePopover: View {
    static let width: CGFloat = 280 // design-literal: the approved card width
    static let logoSize: CGFloat = 17 // design-literal: matches the badge tile, HarnessSessionBadge.diameter
    static let planBarHeight: CGFloat = 4 // design-literal: thin progress bar, no DesignScale role

    let model: AgentBadgePopoverModel
    var now: Date = .now

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale.space[2]) {
            header
            chip
            middle
            Rectangle()
                .fill(theme.color("line"))
                .frame(height: 0.5) // design-literal: hairline
            footer
        }
        .padding(scale.space[3])
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .fill(theme.color("bg-1"))
        )
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color("line"), lineWidth: 0.5) // design-literal: hairline border
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: scale.space[2]) {
            logo
                .frame(width: Self.logoSize, height: Self.logoSize)
            Text(model.title)
                .font(scale.titleFont)
                .foregroundStyle(theme.color("fg"))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let asset = model.agentLogoAsset {
            Image(asset)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
        } else {
            Image(systemName: "sparkles")
                .resizable()
                .scaledToFit()
                .foregroundStyle(theme.color("fg-muted"))
        }
    }

    private var chip: some View {
        HStack(spacing: scale.space[1]) {
            Circle()
                .fill(theme.color(model.status.dotColorToken))
                .frame(width: 6, height: 6) // design-literal: status dot, as the sidebar's HarnessPill
            Text(model.chipText(now: now))
                .font(scale.captionFont)
                .foregroundStyle(theme.color("fg-dim"))
        }
        .padding(.horizontal, scale.space[2])
        .padding(.vertical, scale.space[0])
        .background(Capsule().fill(theme.color("bg-3")))
    }

    @ViewBuilder
    private var middle: some View {
        switch model.body {
        case .none:
            EmptyView()
        case .request(let request):
            HStack(spacing: scale.space[2]) {
                Rectangle()
                    .fill(theme.color("caution"))
                    .frame(width: 2) // design-literal: left rule of a quoted request
                Text(request)
                    .font(scale.meta.font(design: .monospaced))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .plan(let completed, let total, let step):
            VStack(alignment: .leading, spacing: scale.space[1]) {
                Text(AgentBadgePopoverModel.planText(completed: completed, total: total, step: step))
                    .font(scale.metaFont)
                    .foregroundStyle(theme.color("fg-dim"))
                    .lineLimit(1)
                planBar(fraction: total > 0 ? Double(completed) / Double(total) : 0)
            }
        case .excerpt(let excerpt):
            Text(excerpt)
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-dim"))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planBar(fraction: Double) -> some View {
        Capsule()
            .fill(theme.color("bg-3"))
            .frame(height: Self.planBarHeight)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(theme.color("add"))
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
    }

    private var footer: some View {
        HStack(spacing: scale.space[2]) {
            Text(model.footerText)
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Text(model.hintText)
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-faint"))
                .lineLimit(1)
                .fixedSize()
        }
    }
}

extension View {
    /// Shows `AgentBadgePopover` beside this view after 350 ms of hover,
    /// through the sidebar's shared hover tracker. `make` runs only when the
    /// card opens; nil shows nothing. The card is informational: it closes
    /// when hover ends, the list scrolls, the view goes away, or on any click,
    /// key press or scroll, and it never takes key focus.
    func agentBadgePopover(_ make: @escaping @MainActor () -> AgentBadgePopoverModel?) -> some View {
        hoverCard({ make().map { AgentBadgePopover(model: $0) } }, isPinned: false)
    }

    /// As `agentBadgePopover(_:)`, but `isPinned` holds the card open as if
    /// hovered, even while the app is inactive. Only design captures pin it.
    func agentBadgePopover(_ make: @escaping @MainActor () -> AgentBadgePopoverModel?, isPinned: Bool) -> some View {
        hoverCard({ make().map { AgentBadgePopover(model: $0) } }, isPinned: isPinned)
    }

    /// Shows the card `make` returns beside this view, with the same delay,
    /// panel and closing rules as `agentBadgePopover(_:)`.
    func hoverCard<Card: View>(_ make: @escaping @MainActor () -> Card?, isPinned: Bool = false) -> some View {
        modifier(HoverCardModifier(make: make, isPinned: isPinned))
    }
}

private struct HoverCardModifier<Card: View>: ViewModifier {
    static var openDelay: Duration { .milliseconds(350) }

    let make: @MainActor () -> Card?
    let isPinned: Bool

    @State private var isHovering = false
    /// Made on first hover, so a badge at rest carries no AppKit view.
    @State private var presenter: AgentBadgePopoverPresenter?
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    private var isOpen: Bool { isHovering || isPinned }

    func body(content: Content) -> some View {
        content
            .background {
                if isOpen, let presenter {
                    AgentBadgePopoverAnchor(presenter: presenter)
                }
            }
            // The tracker keeps the last closure it was handed, so this only
            // flips state; the task below reads the current `make`.
            .sidebarHover { isHovering = $0 }
            .task(id: isOpen) {
                guard isOpen else {
                    presenter?.close()
                    return
                }
                if presenter == nil { presenter = AgentBadgePopoverPresenter() }
                try? await Task.sleep(for: Self.openDelay)
                guard !Task.isCancelled, let presenter, let card = make() else { return }
                presenter.show(
                    card
                        .environment(\.theme, theme)
                        .environment(\.designScale, scale),
                    isPinned: isPinned
                )
            }
            // The tracker forgets a removed row without reporting the exit.
            .onDisappear {
                isHovering = false
                presenter?.close()
            }
    }
}

/// Places the card in a click-through child panel that can never become key,
/// so the terminal or composer keeps focus while it shows.
@MainActor
final class AgentBadgePopoverPresenter {
    nonisolated static let gap: CGFloat = 6

    weak var anchor: NSView?
    private var panel: NSPanel?
    private var eventMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    isolated deinit {
        close()
    }

    /// A pinned card ignores clicks, keys, scrolls and app deactivation.
    func show(_ content: some View, isPinned: Bool = false) {
        close()
        guard let anchor, let window = anchor.window, window.isVisible else { return }
        let host = NSHostingView(rootView: content)
        host.safeAreaRegions = []
        let size = host.fittingSize
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let anchorMid = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(anchorMid) } ?? window.screen
        let visible = screen?.visibleFrame ?? window.frame
        let panel = AgentBadgePopoverPanel(
            contentRect: Self.frame(size: size, anchor: anchorRect, visible: visible)
        )
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.hidesOnDeactivate = !isPinned
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        panel.invalidateShadow()
        self.panel = panel
        guard !isPinned else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        ) { [weak self] event in
            // Removing the monitor from inside its own handler is not allowed.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.close() } }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    /// Right of the badge, its middle level with the badge's, kept on screen;
    /// on the badge's left when there is no room on the right.
    nonisolated static func frame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        var x = anchor.maxX + gap
        if x + size.width > visible.maxX { x = anchor.minX - gap - size.width }
        x = max(visible.minX, x)
        let y = min(max(anchor.midY - size.height / 2, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

private final class AgentBadgePopoverPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The badge's AppKit view, for placing the panel. Takes no clicks or drags.
private struct AgentBadgePopoverAnchor: NSViewRepresentable {
    let presenter: AgentBadgePopoverPresenter

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        presenter.anchor = nsView
    }

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
