import AppKit
import SwiftUI

/// Reserves a hover-revealed action affordance in the right gutter of a
/// transcript message. The "…" opens a native menu — the per-message action
/// surface. Text actions and fork-from-here share this menu without adding
/// per-action buttons to the transcript row.
///
/// Reusable across message kinds: currently wraps user and agent rows; other
/// block types can opt in later by wrapping their content the same way.
///
/// Layout note: the symmetric reserved *lanes* are applied once by the
/// transcript container (`ACPMessageList`) so every row stays aligned. This
/// wrapper only reveals the button and positions it into the reserved right
/// lane via an offset.
enum ACPMessageCopySource {
    case text(String)
    case streaming(StreamingText)

    @MainActor
    var markdown: String {
        switch self {
        case .text(let text):
            text
        case .streaming(let text):
            text.value
        }
    }
}

struct ACPMessageGutter<Content: View>: View {
    typealias CopySource = ACPMessageCopySource

    /// Produces the raw Markdown copied by "Copy message". Streaming rows keep
    /// a reference to the live buffer so copy reads the latest text without a
    /// per-row closure recreated on every list evaluation.
    let copySource: CopySource
    let forkBoundary: ACPForkMessageBoundary?
    let forkTargets: [ACPSessionForkTarget]
    let onQuote: (String) -> Void
    let onFork: (ACPForkMessageBoundary, String) -> Void
    @ViewBuilder var content: Content

    @StateObject private var hover = ACPDelayedHoverVisibility()
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                dotsMenu
                    // Keep the menu label mounted at all times and toggle
                    // visibility via opacity/hit-testing rather than inserting
                    // and removing the view. Removing the label while its menu
                    // is open can dismiss the menu; this avoids that.
                    .opacity(hover.isVisible ? 1 : 0)
                    .allowsHitTesting(hover.isVisible)
                    // Sit flush with the right edge of the reserved lane: the
                    // button's own visible padding is 4pt each side (8pt total),
                    // so net inset is laneWidth - 8. y: -2 nudges it into optical
                    // alignment with the top of the message content. The offset
                    // intentionally escapes the content view's bounds into the
                    // lane reserved by the container; this relies on no ancestor
                    // applying `clipped()` (SwiftUI does not clip overlays by
                    // default), which also keeps the button hit-testable.
                    .offset(x: ACPMessageGutterLayout.laneWidth - 8, y: -2)
                    // The button sits in the lane, outside `content`'s hover
                    // region, so it must keep itself alive while hovered —
                    // otherwise pointing at it past the hide delay would fade
                    // and disable it mid-aim. Mirrors the old copy button.
                    .onHover { inside in
                        if inside { hover.enter() } else { hover.leave() }
                    }
            }
            .onHover { inside in
                if inside { hover.enter() } else { hover.leave() }
            }
    }

    private var dotsMenu: some View {
        ACPMessageActionsButton(
            copySource: copySource,
            forkBoundary: forkBoundary,
            forkTargets: forkTargets,
            onQuote: onQuote,
            onFork: onFork,
            tint: theme.color("fg-muted")
        )
            .frame(width: 19, height: 19)
            .background(theme.color("bg-3").opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .help("Message actions")
    }
}

private struct ACPMessageActionsButton: NSViewRepresentable {
    let copySource: ACPMessageCopySource
    let forkBoundary: ACPForkMessageBoundary?
    let forkTargets: [ACPSessionForkTarget]
    let onQuote: (String) -> Void
    let onFork: (ACPForkMessageBoundary, String) -> Void
    let tint: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(
            copySource: copySource,
            forkBoundary: forkBoundary,
            forkTargets: forkTargets,
            onQuote: onQuote,
            onFork: onFork
        )
    }

    func makeNSView(context: Context) -> NSButton {
        let button = MessageActionsNSButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.contentTintColor = NSColor(tint)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.copySource = copySource
        context.coordinator.forkBoundary = forkBoundary
        context.coordinator.forkTargets = forkTargets
        context.coordinator.onQuote = onQuote
        context.coordinator.onFork = onFork
        button.contentTintColor = NSColor(tint)
    }

    @MainActor
    final class Coordinator: NSObject {
        var copySource: ACPMessageCopySource
        var forkBoundary: ACPForkMessageBoundary?
        var forkTargets: [ACPSessionForkTarget]
        var onQuote: (String) -> Void
        var onFork: (ACPForkMessageBoundary, String) -> Void

        init(
            copySource: ACPMessageCopySource,
            forkBoundary: ACPForkMessageBoundary?,
            forkTargets: [ACPSessionForkTarget],
            onQuote: @escaping (String) -> Void,
            onFork: @escaping (ACPForkMessageBoundary, String) -> Void
        ) {
            self.copySource = copySource
            self.forkBoundary = forkBoundary
            self.forkTargets = forkTargets
            self.onQuote = onQuote
            self.onFork = onFork
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            let copyItem = NSMenuItem(
                title: "Copy message",
                action: #selector(copyMessage(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            menu.addItem(copyItem)
            let markdown = copySource.markdown
            if ACPMessageQuote.canQuote(markdown) {
                let quoteItem = NSMenuItem(
                    title: "Quote",
                    action: #selector(quoteMessage(_:)),
                    keyEquivalent: ""
                )
                quoteItem.target = self
                menu.addItem(quoteItem)
            }
            if forkBoundary != nil, !forkTargets.isEmpty {
                menu.addItem(.separator())
                let forkItem = NSMenuItem(title: "Fork from here", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for target in forkTargets {
                    let title = target.isSameAgent
                        ? "\(target.displayName)\tSame agent"
                        : target.displayName
                    let item = NSMenuItem(
                        title: title,
                        action: #selector(forkFromHere(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = target.id
                    submenu.addItem(item)
                }
                forkItem.submenu = submenu
                menu.addItem(forkItem)
            }
            menu.popUp(
                positioning: copyItem,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }

        @objc private func copyMessage(_ sender: NSMenuItem) {
            let text = copySource.markdown
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        @objc private func quoteMessage(_ sender: NSMenuItem) {
            let markdown = copySource.markdown
            guard ACPMessageQuote.canQuote(markdown) else { return }
            onQuote(markdown)
        }

        @objc private func forkFromHere(_ sender: NSMenuItem) {
            guard let boundary = forkBoundary,
                  let targetID = sender.representedObject as? String
            else { return }
            onFork(boundary, targetID)
        }
    }
}

private final class MessageActionsNSButton: NSButton {
    private static let ellipsisImage = NSImage(
        systemSymbolName: "ellipsis",
        accessibilityDescription: "Message actions"
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 19, height: 19)
    }

    private func configure() {
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        image = Self.ellipsisImage
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .none
        toolTip = "Message actions"
        setAccessibilityLabel("Message actions")
    }
}

/// Layout metrics for the message gutter. Kept on a non-generic type so the
/// transcript container (`ACPMessageList`) can read `laneWidth` without having
/// to specify `ACPMessageGutter`'s generic `Content` parameter.
enum ACPMessageGutterLayout {
    /// Width of each reserved side lane. The left lane stays empty (reads as
    /// padding); the right lane hosts the "…" on hover.
    static let laneWidth: CGFloat = 32
}
