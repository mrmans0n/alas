import SwiftUI

/// A paired Mac's chosen glyph. Every view that names a specific peer draws
/// it through here, so one peer never reads as a laptop in one place and a
/// rack in another.
struct PeerIconView: View {
    let icon: PeerIcon
    /// Nil inherits the surrounding font.
    var size: CGFloat?

    var body: some View {
        // `.font(nil)` would reset the font rather than inherit it.
        if let size {
            glyph.font(.system(size: size))
        } else {
            glyph
        }
    }

    private var glyph: some View {
        Image(systemName: icon.symbolName).accessibilityHidden(true)
    }
}

/// The peer's glyph on a bordered tile, with a presence dot punched out of
/// its bottom-trailing corner. 19pt beside repo headers; larger on the peer
/// page's header and in Settings.
struct PeerIconTile: View {
    let icon: PeerIcon
    /// Theme token for the presence dot; nil draws no dot.
    var presenceToken: String?
    var side: CGFloat = 19 // design-literal: icon tile

    var body: some View {
        SymbolTile(symbol: icon.symbolName, presenceToken: presenceToken, side: side)
    }
}

/// Any SF Symbol on the tile `PeerIconTile` draws, for rows that stand for a
/// device that is not a Mac, such as a phone or a browser.
struct SymbolTile: View {
    let symbol: String
    var presenceToken: String?
    var side: CGFloat = 19 // design-literal: icon tile
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    private var dot: CGFloat { side >= 24 ? 8 : 6 }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.55))
            .foregroundColor(theme.color(side >= 24 ? "fg" : "fg-muted"))
            .frame(width: side, height: side)
            .background(theme.color("bg-4"), in: RoundedRectangle(cornerRadius: scale.radius.small))
            .overlay {
                RoundedRectangle(cornerRadius: scale.radius.small)
                    .strokeBorder(theme.color("line"), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if presenceToken != nil {
                    // The sidebar is a translucent material, so punch a real
                    // gap out of the tile instead of painting a ring.
                    Circle()
                        .frame(width: dot + 4, height: dot + 4)
                        .offset(x: dot / 2 + 1, y: dot / 2 + 1)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .overlay(alignment: .bottomTrailing) {
                if let presenceToken {
                    Circle()
                        .fill(theme.color(presenceToken))
                        .frame(width: dot, height: dot)
                        .offset(x: dot / 3, y: dot / 3)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The Settings control for this Mac's own icon: a pop-up showing the
/// current glyph and label that opens a grid of every icon.
struct PeerIconPicker: View {
    @Binding var icon: PeerIcon
    @Environment(\.designScale) private var scale
    @Environment(\.theme) private var theme
    @State private var open = false

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 6) {
                PeerIconView(icon: icon)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg"))
                Text(icon.label)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(scale.glyphFont)
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, scale.space[2])
            .frame(height: 24)
            .background(theme.color("bg-0"))
            .overlay(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
        }
        .buttonStyle(.plain)
        .settingsDropdownFrame()
        .accessibilityLabel("Icon")
        .accessibilityValue(icon.label)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PeerIconGrid(selection: icon) { picked in
                icon = picked
                open = false
            }
        }
    }
}

/// Every `PeerIcon` in a grid, for a picker's popover. `resetTitle` adds a
/// button under the grid that calls `onReset`.
struct PeerIconGrid: View {
    let selection: PeerIcon
    var resetTitle: String? = nil
    let onPick: (PeerIcon) -> Void
    var onReset: () -> Void = {}
    @Environment(\.designScale) private var scale
    @Environment(\.theme) private var theme

    private static let columns = Array(repeating: GridItem(.fixed(44), spacing: 6), count: 4) // design-literal: icon grid cell

    var body: some View {
        VStack(spacing: scale.space[2]) {
            LazyVGrid(columns: Self.columns, spacing: 6) {
                ForEach(PeerIcon.allCases) { option in
                    cell(option)
                }
            }
            if let resetTitle {
                AlasButton(title: resetTitle, style: .subtle, action: onReset)
            }
        }
        .padding(scale.space[2])
    }

    private func cell(_ option: PeerIcon) -> some View {
        let selected = option == selection
        return Button {
            onPick(option)
        } label: {
            PeerIconView(icon: option, size: 18)
                .foregroundColor(theme.color(selected ? "accent" : "fg"))
                .frame(width: 44, height: 36)
                .background(
                    selected ? theme.color("accent-soft") : Color.clear,
                    in: RoundedRectangle(cornerRadius: scale.radius.medium)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option.label)
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A paired Mac's tile that opens `PeerIconGrid` to pick the icon this Mac
/// shows for it. `onPick(nil)` goes back to the icon the peer advertises.
struct PeerIconTileButton: View {
    let icon: PeerIcon
    let presenceToken: String
    let side: CGFloat
    let peerName: String
    let isOverridden: Bool
    let onPick: (PeerIcon?) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            PeerIconTile(icon: icon, presenceToken: presenceToken, side: side)
        }
        .buttonStyle(.plain)
        .help("Change the icon this Mac shows for \(peerName)")
        .accessibilityLabel("Icon")
        .accessibilityValue(icon.label)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PeerIconGrid(
                selection: icon,
                resetTitle: isOverridden ? "Use \(peerName)'s own" : nil,
                onPick: { picked in
                    onPick(picked)
                    open = false
                },
                onReset: {
                    onPick(nil)
                    open = false
                }
            )
        }
    }
}
