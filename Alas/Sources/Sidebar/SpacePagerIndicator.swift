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
    static func isActive(spaceID: String, activeSpaceID: String) -> Bool {
        spaceID == activeSpaceID
    }

    static func offset(activeSpaceID: String, spaces: [SpaceConfig], pageWidth: CGFloat) -> CGFloat {
        guard let index = spaces.firstIndex(where: { $0.id == activeSpaceID }) else { return 0 }
        return -CGFloat(index) * pageWidth
    }
}

/// Only the page contents move; the header and page controls stay anchored.
struct SpacePagerContent<Content: View>: View {
    let spaces: [SpaceConfig]
    let selection: String
    @ViewBuilder let content: (String) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(spaces) { space in
                    let isActive = SpacePagerLayout.isActive(spaceID: space.id, activeSpaceID: selection)
                    content(space.id)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(isActive)
                        .disabled(!isActive)
                        .accessibilityHidden(!isActive)
                }
            }
            .offset(x: SpacePagerLayout.offset(
                activeSpaceID: selection,
                spaces: spaces,
                pageWidth: geometry.size.width
            ))
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: selection)
        }
        .clipped()
    }
}

struct SpacePagerIndicator: View {
    let spaces: [SpaceConfig]
    let activeSpaceId: String
    let titleVisible: Bool
    let onSelectSpace: (String) -> Void
    let onEditSpaces: () -> Void
    let onScrollPage: (Int) -> Void
    @Environment(\.theme) var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionHighlight

    var body: some View {
        VStack(spacing: 6) {
            if let active = spaces.first(where: { $0.id == activeSpaceId }) {
                Text(active.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                    .lineLimit(1)
                    .opacity(titleVisible ? 1 : 0)
            }
            HStack(spacing: 10) {
                ForEach(spaces) { space in
                    let style = SpacePagerItemStyle.style(isActive: space.id == activeSpaceId)
                    Button {
                        onSelectSpace(space.id)
                    } label: {
                        SpaceIconLabel(icon: space.emoji, size: 15)
                            .opacity(style.opacity)
                            .saturation(style.isGrayscale ? 0 : 1)
                            .frame(width: 22, height: 22)
                            .background {
                                if space.id == activeSpaceId {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(theme.color("fg-muted").opacity(0.15))
                                        .matchedGeometryEffect(id: "selection", in: selectionHighlight)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(space.name)
                    .accessibilityLabel(space.name)
                    .accessibilityValue(space.id == activeSpaceId ? "selected" : "not selected")
                    .contextMenu {
                        Button("Edit Space...") {
                            onEditSpaces()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: titleVisible)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: activeSpaceId)
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

    private var accessibilityValue: String {
        guard let index = spaces.firstIndex(where: { $0.id == activeSpaceId }) else { return "" }
        return "\(spaces[index].name), \(index + 1) of \(spaces.count)"
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
