import SwiftUI
import AppKit

struct SpacePagerItemStyle: Equatable {
    let opacity: Double
    let isGrayscale: Bool

    static func style(isActive: Bool) -> SpacePagerItemStyle {
        SpacePagerItemStyle(opacity: isActive ? 1.0 : 0.55, isGrayscale: !isActive)
    }
}

enum SpacePagingIntent {
    static func offset(deltaX: CGFloat, deltaY: CGFloat) -> Int? {
        guard abs(deltaX) >= 24,
              abs(deltaX) > abs(deltaY) * 1.4
        else { return nil }
        return deltaX < 0 ? 1 : -1
    }
}

struct SpacePagingScrollGate {
    struct Result {
        var page: Int?
        var capturesScroll: Bool
    }
    private enum Axis { case horizontal, vertical }
    private var lastEventAt: TimeInterval?
    private var axis: Axis?
    private var deltaX: CGFloat = 0
    private var deltaY: CGFloat = 0
    private var didPage = false
    private var gestureInProgress = false

    mutating func consume(
        deltaX: CGFloat, deltaY: CGFloat, phase: NSEvent.Phase,
        momentumPhase: NSEvent.Phase, now: TimeInterval
    ) -> Result {
        // Momentum belongs to the completed gesture, regardless of its duration.
        guard momentumPhase.isEmpty else {
            return Result(capturesScroll: axis == .horizontal)
        }
        let unphased = phase.isEmpty
        if phase.contains(.began) { gestureInProgress = true }
        if phase.contains(.began) || (unphased && (lastEventAt.map { now - $0 > 0.34 } ?? true)) {
            axis = nil
            self.deltaX = 0
            self.deltaY = 0
            didPage = false
        }
        lastEventAt = now
        if phase.contains(.ended) || phase.contains(.cancelled) {
            gestureInProgress = false
            return Result(capturesScroll: axis == .horizontal)
        }
        guard !phase.contains(.mayBegin), unphased || gestureInProgress else {
            return Result(capturesScroll: false)
        }
        self.deltaX += deltaX
        self.deltaY += deltaY
        if axis == nil {
            if abs(self.deltaY) >= 8, abs(self.deltaY) > abs(self.deltaX) {
                axis = .vertical
            } else if abs(self.deltaX) >= 8, abs(self.deltaX) > abs(self.deltaY) * 1.4 {
                axis = .horizontal
            }
        }
        guard axis == .horizontal else { return Result(capturesScroll: false) }
        guard !didPage,
              let page = SpacePagingIntent.offset(deltaX: self.deltaX, deltaY: 0)
        else { return Result(capturesScroll: true) }
        didPage = true
        return Result(page: page, capturesScroll: true)
    }
}

enum SpacePagerNavigation {
    static func destination(current: Int, offset: Int, count: Int) -> Int? {
        guard (0..<count).contains(current), offset == -1 || offset == 1 else { return nil }
        let next = current + offset
        return (0..<count).contains(next) ? next : nil
    }
}

enum SpacePagerLayout {
    static func offset(active: SidebarPage, pages: [SidebarPage], pageWidth: CGFloat) -> CGFloat {
        guard let index = pages.firstIndex(of: active) else { return 0 }
        return -CGFloat(index) * pageWidth
    }
}

/// Only the page contents move; the header and page controls stay anchored.
struct SpacePagerContent<SpaceContent: View, PeerContent: View>: View {
    let pages: [SidebarPage]
    let selection: SidebarPage
    @ViewBuilder let space: (String) -> SpaceContent
    @ViewBuilder let peer: (String) -> PeerContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(pages) { page in
                    let isActive = page == selection
                    Group {
                        switch page {
                        case .space(let id): space(id)
                        case .peer(let serverId): peer(serverId)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .allowsHitTesting(isActive)
                    .accessibilityHidden(!isActive)
                }
            }
            .offset(x: SpacePagerLayout.offset(active: selection, pages: pages, pageWidth: geometry.size.width))
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: selection)
        }
        .clipped()
    }
}

/// The user's spaces as emoji, then a divider and one item per paired Mac.
struct SpacePagerIndicator: View {
    let spaces: [SpaceConfig]
    let peers: [NativePeerPage]
    let active: SidebarPage
    let titleVisible: Bool
    let onSelect: (SidebarPage) -> Void
    let onEditSpaces: () -> Void
    let onRemoteSettings: () -> Void
    let onScrollPage: (Int) -> Void
    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionHighlight

    var body: some View {
        VStack(spacing: 6) {
            if let title {
                Text(title)
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
                    .opacity(titleVisible ? 1 : 0)
            }
            HStack(spacing: 10) {
                ForEach(spaces) { space in
                    let isActive = active == .space(space.id)
                    let style = SpacePagerItemStyle.style(isActive: isActive)
                    Button {
                        onSelect(.space(space.id))
                    } label: {
                        SpaceIconLabel(icon: space.emoji, size: 15)
                            .opacity(style.opacity)
                            .saturation(style.isGrayscale ? 0 : 1)
                            .frame(width: 22, height: 22)
                            .background { highlight(isActive) }
                    }
                    .buttonStyle(.plain)
                    .help(space.name)
                    .accessibilityLabel(space.name)
                    .accessibilityValue(isActive ? "selected" : "not selected")
                    .contextMenu {
                        Button("Edit Space...") {
                            onEditSpaces()
                        }
                    }
                }
                if !peers.isEmpty {
                    Rectangle()
                        .fill(theme.color("line"))
                        .frame(width: 1, height: 14)
                        .accessibilityHidden(true)
                }
                ForEach(peers) { peer in
                    let isActive = active == .peer(serverId: peer.serverId)
                    Button {
                        onSelect(.peer(serverId: peer.serverId))
                    } label: {
                        PeerPagerItem(peer: peer, isActive: isActive)
                            .frame(width: 22, height: 22)
                            .background { highlight(isActive) }
                    }
                    .buttonStyle(.plain)
                    .help("\(peer.name) · \(peer.state.label)")
                    .accessibilityLabel(peer.name)
                    .accessibilityValue((isActive ? "selected, " : "") + peer.accessibilityValue)
                    .contextMenu {
                        Button("Remote Settings…", action: onRemoteSettings)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, scale.space[3])
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: titleVisible)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: active)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onScrollPage(1)
            case .decrement: onScrollPage(-1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func highlight(_ isActive: Bool) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .fill(theme.color("fg-muted").opacity(0.15))
                .matchedGeometryEffect(id: "selection", in: selectionHighlight)
        }
    }

    private var title: String? {
        switch active {
        case .space(let id): spaces.first { $0.id == id }?.name
        case .peer(let serverId): peers.first { $0.serverId == serverId }?.name
        }
    }

    private var accessibilityValue: String {
        let pages = SidebarPages.pages(spaceIds: spaces.map(\.id), peerServerIds: peers.map(\.serverId))
        guard let index = pages.firstIndex(of: active), let title else { return "" }
        return "\(title), \(index + 1) of \(pages.count)"
    }
}

/// A paired Mac in the pager: its glyph in place of a space's emoji, a
/// presence dot, and an orange count while its sessions wait on you. A Mac
/// that is away keeps its slot, faded, so no position or ⌥⌘ number moves.
private struct PeerPagerItem: View {
    let peer: NativePeerPage
    let isActive: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        PeerIconView(icon: peer.icon, size: 14)
            .foregroundColor(theme.color(isActive ? "fg" : "fg-muted"))
            .opacity(peer.state.carriesSessions ? 1 : (isActive ? 0.8 : 0.45))
            .frame(width: 22, height: 22)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(theme.color(peer.state.presenceColorToken))
                    .frame(width: 6, height: 6)
                    .offset(x: -1, y: -1)
            }
            .overlay(alignment: .topTrailing) {
                if peer.attentionCount > 0 {
                    Text("\(peer.attentionCount)")
                        .font(.system(size: 8.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 12, minHeight: 12)
                        .background(theme.color("mod"), in: Capsule())
                        .offset(x: 5, y: -4)
                }
            }
    }
}

struct SpaceIconLabel: View {
    let icon: String
    let size: CGFloat

    var body: some View {
        Text(icon)
            .font(.system(size: size))
    }
}

struct SpacePagerScrollCaptureView: NSViewRepresentable {
    let onPage: (Int) -> Void

    func makeNSView(context: Context) -> Backing {
        let view = Backing()
        view.onPage = onPage
        return view
    }

    func updateNSView(_ nsView: Backing, context: Context) {
        nsView.onPage = onPage
    }

    final class Backing: NSView {
        var onPage: ((Int) -> Void)?
        private var monitor: Any?
        private var gate = SpacePagingScrollGate()

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeMonitor()
            } else {
                installMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func scrollWheel(with event: NSEvent) {
            if handle(event: event) {
                return
            }
            super.scrollWheel(with: event)
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      !isHiddenOrHasHiddenAncestor,
                      let window,
                      event.window === window
                else { return event }

                let location = convert(event.locationInWindow, from: nil)
                guard bounds.contains(location) else { return event }

                return handle(event: event) ? nil : event
            }
        }

        private func handle(event: NSEvent) -> Bool {
            let result = gate.consume(
                deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                phase: event.phase, momentumPhase: event.momentumPhase, now: event.timestamp
            )
            if let page = result.page { onPage?(page) }
            return result.capturesScroll
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            gate = SpacePagingScrollGate()
        }
    }
}
