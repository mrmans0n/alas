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
        return deltaX > 0 ? 1 : -1
    }
}

struct SpacePagingScrollGate {
    private static let quietInterval: TimeInterval = 0.34

    private var lastEventAt: TimeInterval?
    private var didAcceptInCurrentBurst = false

    mutating func consume(offset: Int, now: TimeInterval) -> Int? {
        let startsNewBurst = lastEventAt.map { now - $0 > Self.quietInterval } ?? true
        lastEventAt = now

        if startsNewBurst {
            didAcceptInCurrentBurst = false
        }

        guard !didAcceptInCurrentBurst else {
            return nil
        }

        didAcceptInCurrentBurst = true
        return offset
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

    var body: some View {
        VStack(spacing: 6) {
            if titleVisible, let active = spaces.first(where: { $0.id == activeSpaceId }) {
                Text(active.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                    .transition(.opacity)
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
        .animation(.easeInOut(duration: 0.18), value: titleVisible)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Spaces")
        .accessibilityValue(accessibilityValue)
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

        override func swipe(with event: NSEvent) {
            if handle(event: event) {
                return
            }
            super.swipe(with: event)
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
                guard let self,
                      let window,
                      event.window === window
                else { return event }

                let location = convert(event.locationInWindow, from: nil)
                guard bounds.contains(location) else { return event }

                return handle(event: event) ? nil : event
            }
        }

        private func handle(event: NSEvent) -> Bool {
            let deltaX = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.deltaX
            let deltaY = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            guard let offset = SpacePagingIntent.offset(deltaX: deltaX, deltaY: deltaY),
                  let page = gate.consume(offset: offset, now: Date().timeIntervalSinceReferenceDate)
            else { return false }
            onPage?(page)
            return true
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }
    }
}
