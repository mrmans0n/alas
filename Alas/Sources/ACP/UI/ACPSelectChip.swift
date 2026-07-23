import AppKit
import SwiftUI

/// Styled chip + custom popover dropdown used for the composer's model and
/// mode pickers. Shows a label and chevron; tapping opens a popover with
/// optional search (auto-shown when items > 5) and a list of rows. Mirrors
/// the design's `chat-model` button visual.
struct ACPSelectChip: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let description: String?
    }

    let label: String
    let placeholder: String
    let accent: Color
    let items: [Item]
    let selectedId: String?
    let searchDescriptions: Bool
    let searchIdentifiers: Bool
    let onSelect: (Item) -> Void

    @Environment(\.theme) private var theme
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            // Matches Anthropic's `.chat-model` chip in the Alas design
            // handoff: dark accent-tinted fill, 0.5px accent-colored
            // outline at low opacity, accent-tinted (not white) text.
            // Outline-on-fill, not a solid bright pill.
            HStack(spacing: ACPSelectChipMetrics.labelChevronSpacing) {
                Text(label.isEmpty ? placeholder : label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.labelForeground(accent: accent, theme: theme))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(accent.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(accent.opacity(0.45), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .disabled(items.isEmpty)
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            DropdownPanel(
                items: items,
                selectedId: selectedId,
                accent: accent,
                searchDescriptions: searchDescriptions,
                searchIdentifiers: searchIdentifiers,
                onSelect: { item in
                    onSelect(item)
                    showPopover = false
                }
            )
            .environment(\.theme, theme)
        }
    }

    /// Case-insensitive substring filter used by the dropdown. Model pickers
    /// disable hidden metadata matching so invisible ids/descriptions do not
    /// keep display-name misses in the result list.
    static func filteredItems(
        _ items: [Item],
        query: String,
        searchDescriptions: Bool = true,
        searchIdentifiers: Bool = true
    ) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return items }
        return items.filter {
            $0.name.lowercased().contains(q)
                || (searchIdentifiers && $0.id.lowercased().contains(q))
                || (searchDescriptions && ($0.description?.lowercased().contains(q) ?? false))
        }
    }

    static func labelForeground(accent: Color, theme: Theme) -> Color {
        if theme.darkMode {
            return Color.blend(accent, .white, t: 0.55)
        }

        let chipBackground = composited(foreground: accent, alpha: 0.18, over: theme.color("bg-1"))
        let minimumContrast = 4.5
        let preferredBlend = Color.blend(accent, .black, t: 0.30)
        if contrastRatio(preferredBlend, chipBackground) >= minimumContrast {
            return preferredBlend
        }

        var lower = 0.30
        var upper = 1.0
        for _ in 0..<12 {
            let midpoint = (lower + upper) / 2
            let candidate = Color.blend(accent, .black, t: midpoint)
            if contrastRatio(candidate, chipBackground) >= minimumContrast {
                upper = midpoint
            } else {
                lower = midpoint
            }
        }
        return Color.blend(accent, .black, t: upper)
    }

    private struct ColorComponents {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    private static func colorComponents(_ color: Color) -> ColorComponents {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return ColorComponents(
            red: Double(nsColor.redComponent),
            green: Double(nsColor.greenComponent),
            blue: Double(nsColor.blueComponent),
            alpha: Double(nsColor.alphaComponent)
        )
    }

    private static func composited(foreground: Color, alpha: Double, over background: Color) -> Color {
        let fg = colorComponents(foreground)
        let bg = colorComponents(background)
        let a = max(0, min(1, alpha))
        return Color(
            .sRGB,
            red: fg.red * a + bg.red * (1 - a),
            green: fg.green * a + bg.green * (1 - a),
            blue: fg.blue * a + bg.blue * (1 - a),
            opacity: fg.alpha * a + bg.alpha * (1 - a)
        )
    }

    private static func contrastRatio(_ lhs: Color, _ rhs: Color) -> Double {
        let l1 = relativeLuminance(lhs)
        let l2 = relativeLuminance(rhs)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private static func relativeLuminance(_ color: Color) -> Double {
        let c = colorComponents(color)
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }
}

enum ACPSelectChipMetrics {
    static let labelChevronSpacing: CGFloat = 5
    static let leadingIndicatorDiameter: CGFloat = 0
}

/// Popover content: optional search field + scrollable list.
private struct DropdownPanel: View {
    let items: [ACPSelectChip.Item]
    let selectedId: String?
    let accent: Color
    let searchDescriptions: Bool
    let searchIdentifiers: Bool
    let onSelect: (ACPSelectChip.Item) -> Void

    @Environment(\.theme) private var theme
    @State private var query: String = ""
    @State private var highlight: Int = 0
    /// Bumps only on keyboard navigation. The scroll tracker watches
    /// this — NOT `highlight` — so hovering with the mouse can update
    /// the row tint without scrolling the list. The previous setup made
    /// hover → highlight → scroll → cursor over new row → loop, which
    /// produced the jumpy feel.
    @State private var keyboardScrollTick: Int = 0
    @FocusState private var searchFocused: Bool

    private var showSearch: Bool { items.count > 5 }

    private var filtered: [ACPSelectChip.Item] {
        ACPSelectChip.filteredItems(
            items,
            query: query,
            searchDescriptions: searchDescriptions,
            searchIdentifiers: searchIdentifiers
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if showSearch {
                searchBar
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, item in
                            row(idx: idx, item: item)
                                // Data-based id, not the row position: a
                                // positional id freezes LazyVStack rows against
                                // the substring filter shrinking the list.
                                .id(item.id)
                        }
                        if filtered.isEmpty {
                            Text("No matches")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.color("fg-faint"))
                                .padding(.horizontal, 10).padding(.vertical, 10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: keyboardScrollTick) { _, _ in
                    let items = filtered
                    guard items.indices.contains(highlight) else { return }
                    withAnimation(.easeOut(duration: 0.10)) {
                        proxy.scrollTo(items[highlight].id, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 280)
        .frame(maxHeight: 260)
        .background(theme.color("bg-1"))
        .onKeyPress { press in
            switch press.key {
            case .upArrow:
                highlight = max(0, highlight - 1)
                keyboardScrollTick &+= 1
                return .handled
            case .downArrow:
                highlight = min(max(0, filtered.count - 1), highlight + 1)
                keyboardScrollTick &+= 1
                return .handled
            case .return:
                if filtered.indices.contains(highlight) {
                    onSelect(filtered[highlight])
                }
                return .handled
            default:
                return .ignored
            }
        }
        .onAppear {
            searchFocused = showSearch
            // Seed the highlight at the currently selected item so ↑↓
            // (and the visible row tint) starts where the user is now,
            // not at index 0.
            if let selectedId,
               let idx = filtered.firstIndex(where: { $0.id == selectedId }) {
                highlight = idx
                keyboardScrollTick &+= 1
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-faint"))
            TextField("Search…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onChange(of: query) { _, _ in highlight = 0 }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(theme.color("bg-0").opacity(0.6))
    }

    @ViewBuilder
    private func row(idx: Int, item: ACPSelectChip.Item) -> some View {
        let isSelected = item.id == selectedId
        let isHighlighted = idx == highlight
        Button { onSelect(item) } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(theme.color("fg"))
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(accent)
                        }
                    }
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(rowBg(isHighlighted: isHighlighted, isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlight = idx }
        }
    }

    private func rowBg(isHighlighted: Bool, isSelected: Bool) -> Color {
        if isHighlighted { return accent.opacity(0.15) }
        if isSelected    { return accent.opacity(0.07) }
        return .clear
    }
}
