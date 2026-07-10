import AppKit
import SwiftUI

/// Reserves a hover-revealed action affordance in the right gutter of a
/// transcript message. The "…" opens a native menu — the per-message action
/// surface. Today it carries a single action ("Copy message"); future
/// actions (e.g. fork-from-here) slot in as additional buttons with no
/// structural change.
///
/// Reusable across message kinds: currently wraps user and agent rows; other
/// block types can opt in later by wrapping their content the same way.
///
/// Layout note: the symmetric reserved *lanes* are applied once by the
/// transcript container (`ACPMessageList`) so every row stays aligned. This
/// wrapper only reveals the button and positions it into the reserved right
/// lane via an offset.
struct ACPMessageGutter<Content: View>: View {
    enum CopySource {
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

    /// Produces the raw Markdown copied by "Copy message". Streaming rows keep
    /// a reference to the live buffer so copy reads the latest text without a
    /// per-row closure recreated on every list evaluation.
    let copySource: CopySource
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
        Menu {
            Button("Copy message") {
                let text = copySource.markdown
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.color("fg-muted"))
                .padding(4)
                .background(theme.color("bg-3").opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(theme.color("line"), lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Message actions")
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
