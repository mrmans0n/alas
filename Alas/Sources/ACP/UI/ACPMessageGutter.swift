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

/// An action another feature adds to the "…" menu, such as a plugin command (API 7 `message.menu`). `run` gets the
/// message's Markdown.
struct ACPMessageMenuItem {
    let title: String
    let icon: String?
    let run: (String) -> Void
}

struct ACPMessageGutter<Content: View>: View {
    typealias CopySource = ACPMessageCopySource

    /// Produces the raw Markdown copied by "Copy message". Streaming rows keep
    /// a reference to the live buffer so copy reads the latest text without a
    /// per-row closure recreated on every list evaluation.
    let copySource: CopySource
    let messageCreatedAt: Date?
    let showsInlineTimestamp: Bool
    let forkBoundary: ACPForkMessageBoundary?
    let forkTargets: [ACPSessionForkTarget]
    let onQuote: (String) -> Void
    let onFork: (ACPForkMessageBoundary, String) -> Void
    let checkpointID: CheckpointID?
    let onRestoreCheckpoint: (CheckpointID) -> Void
    var messageMenuItems: () -> [ACPMessageMenuItem] = { [] }
    @ViewBuilder var content: Content

    @StateObject private var hover = ACPDelayedHoverVisibility()
    /// The actions are built on first hover, not with the row: their menu
    /// button is an AppKit view, and every platform view costs a layout pass
    /// when its row mounts mid-scroll. Once built they stay mounted (see below).
    @State private var hasRevealedActions = false
    /// VoiceOver and keyboard users never hover, so for them the actions are
    /// built with the row and stay visible and reachable.
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    private var showsActionsWithoutHover: Bool {
        voiceOverEnabled || NSApp.isFullKeyboardAccessEnabled
    }
    @Environment(\.theme) private var theme

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if hasRevealedActions || showsActionsWithoutHover {
                    actions
                        // Keep the menu label mounted at all times and toggle
                        // visibility via opacity/hit-testing rather than inserting
                        // and removing the view. Removing the label while its menu
                        // is open can dismiss the menu; this avoids that.
                        .opacity(hover.isVisible || showsActionsWithoutHover ? 1 : 0)
                        .allowsHitTesting(hover.isVisible || showsActionsWithoutHover)
                        // Sit flush with the right edge of the reserved lane: the
                        // button's own visible padding is 4pt each side (8pt total),
                        // so net inset is laneWidth - 8. y: -2 nudges it into optical
                        // alignment with the top of the message content. The offset
                        // intentionally escapes the content view's bounds into the
                        // lane reserved by the container; this relies on no ancestor
                        // applying `clipped()` (SwiftUI does not clip overlays by
                        // default), which also keeps the button hit-testable.
                        .offset(x: actionsOffsetX, y: -2)
                }
            }
            // The whole row, lane included, so the button stays alive while
            // the pointer travels to it.
            .acpRowHover { inside in
                if inside {
                    hasRevealedActions = true
                    hover.enter()
                } else {
                    hover.leave()
                }
            }
            .onDisappear { hover.reset() }
    }

    @ViewBuilder private var actions: some View {
        if showsInlineTimestamp, messageCreatedAt != nil {
            VStack(alignment: .leading, spacing: ACPMessageGutterLayout.timestampVerticalSpacing) {
                actionButtons
                timestamp
            }
            .frame(width: ACPMessageGutterLayout.timestampWidth, alignment: .leading)
        } else {
            actionButtons
        }
    }

    private var actionsOffsetX: CGFloat {
        let expandedWidth = showsInlineTimestamp && messageCreatedAt != nil
            ? ACPMessageGutterLayout.timestampWidth - ACPMessageGutterLayout.menuWidth
            : 0
        return ACPMessageGutterLayout.laneWidth - 8 + expandedWidth
    }

    @ViewBuilder private var timestamp: some View {
        if let messageCreatedAt {
            Text(ACPMessageTimestampFormatter.string(for: messageCreatedAt))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(theme.color("fg-faint"))
                .accessibilityHidden(true)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if showsInlineTimestamp, messageCreatedAt != nil, let checkpointID {
                Button {
                    onRestoreCheckpoint(checkpointID)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 19, height: 19)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.color("fg-muted"))
                .background(theme.color("bg-3").opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
                .help("Restore files to before this request")
                .accessibilityLabel("Restore files to before this request")
            }
            dotsMenu
        }
    }
    private var dotsMenu: some View {
        ACPMessageActionsButton(
            copySource: copySource,
            createdAt: messageCreatedAt,
            forkBoundary: forkBoundary,
            forkTargets: forkTargets,
            onQuote: onQuote,
            onFork: onFork,
            checkpointID: checkpointID,
            onRestoreCheckpoint: onRestoreCheckpoint,
            messageMenuItems: messageMenuItems,
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
    let createdAt: Date?
    let forkBoundary: ACPForkMessageBoundary?
    let forkTargets: [ACPSessionForkTarget]
    let onQuote: (String) -> Void
    let onFork: (ACPForkMessageBoundary, String) -> Void
    let checkpointID: CheckpointID?
    let onRestoreCheckpoint: (CheckpointID) -> Void
    let messageMenuItems: () -> [ACPMessageMenuItem]
    let tint: Color

    func makeCoordinator() -> Coordinator {
        Coordinator(
            copySource: copySource,
            createdAt: createdAt,
            forkBoundary: forkBoundary,
            forkTargets: forkTargets,
            onQuote: onQuote,
            checkpointID: checkpointID,
            onRestoreCheckpoint: onRestoreCheckpoint,
            messageMenuItems: messageMenuItems,
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
        context.coordinator.createdAt = createdAt
        context.coordinator.forkBoundary = forkBoundary
        context.coordinator.forkTargets = forkTargets
        context.coordinator.onQuote = onQuote
        context.coordinator.onFork = onFork
        context.coordinator.checkpointID = checkpointID
        context.coordinator.onRestoreCheckpoint = onRestoreCheckpoint
        context.coordinator.messageMenuItems = messageMenuItems
        button.contentTintColor = NSColor(tint)
    }

    @MainActor
    final class Coordinator: NSObject {
        var copySource: ACPMessageCopySource
        var createdAt: Date?
        var forkBoundary: ACPForkMessageBoundary?
        var forkTargets: [ACPSessionForkTarget]
        var onQuote: (String) -> Void
        var onFork: (ACPForkMessageBoundary, String) -> Void
        var checkpointID: CheckpointID?
        var onRestoreCheckpoint: (CheckpointID) -> Void
        var messageMenuItems: () -> [ACPMessageMenuItem]

        init(
            copySource: ACPMessageCopySource,
            createdAt: Date?,
            forkBoundary: ACPForkMessageBoundary?,
            forkTargets: [ACPSessionForkTarget],
            onQuote: @escaping (String) -> Void,
            checkpointID: CheckpointID?,
            onRestoreCheckpoint: @escaping (CheckpointID) -> Void,
            messageMenuItems: @escaping () -> [ACPMessageMenuItem],
            onFork: @escaping (ACPForkMessageBoundary, String) -> Void
        ) {
            self.copySource = copySource
            self.createdAt = createdAt
            self.forkBoundary = forkBoundary
            self.forkTargets = forkTargets
            self.onQuote = onQuote
            self.checkpointID = checkpointID
            self.onRestoreCheckpoint = onRestoreCheckpoint
            self.messageMenuItems = messageMenuItems
            self.onFork = onFork
        }

        @objc func showMenu(_ sender: NSButton) {
            let source = copySource
            let menu = ACPMessageActionsMenu.make(.init(
                markdown: { source.markdown },
                createdAt: createdAt,
                checkpointID: checkpointID,
                forkBoundary: forkBoundary,
                forkTargets: forkTargets,
                onQuote: onQuote,
                onFork: onFork,
                onRestoreCheckpoint: onRestoreCheckpoint,
                messageMenuItems: messageMenuItems
            ))
            menu.popUp(
                positioning: menu.items.first { $0.title == "Copy message" },
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
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
    static let menuWidth: CGFloat = 19
    static let inlineTimestampMinimumContentWidth: CGFloat = 520
    static let timestampVerticalSpacing: CGFloat = 4
    static let timestampWidth: CGFloat = 128
    static let inlineTimestampTrailingExtent: CGFloat = laneWidth - 8 + timestampWidth - menuWidth
}
