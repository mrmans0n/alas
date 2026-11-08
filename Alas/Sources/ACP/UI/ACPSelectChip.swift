import AppKit
import SwiftUI

/// Styled chip + custom popover dropdown used for the composer's model and
/// mode pickers. Shows a label and chevron; tapping opens a popover with
/// optional search (auto-shown when items > 5) and a list of rows. Mirrors
/// the design's `chat-model` button visual.
struct ACPSelectChip: View {
    enum Icon: Equatable {
        case system(String)
        /// Full-color artwork, such as an agent logo; drawn untinted.
        case image(NSImage)
    }

    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let description: String?
        /// Shown before the name: mode symbols in the composer, agent logos
        /// in the peer new-session sheet. Absent for every other chip.
        var icon: Icon? = nil
        /// A short note after the name, such as "Recommended".
        var badge: String? = nil
    }

    let label: String
    let placeholder: String
    let accent: Color
    /// Drawn before the label, whatever is selected.
    var leadingSymbol: String? = nil
    /// The chip itself has no state to show, so it stays grey. `accent` still
    /// marks the selected row in its popover.
    var isNeutral = false
    let items: [Item]
    let selectedId: String?
    let searchDescriptions: Bool
    let searchIdentifiers: Bool
    let fillsWidth: Bool
    let onSelect: (Item) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            // Neutral, or a dark accent-tinted fill and accent-tinted (not
            // white) text when the accent means a state; never a solid bright pill.
            HStack(spacing: ACPSelectChipMetrics.labelChevronSpacing) {
                if let leadingSymbol {
                    Image(systemName: leadingSymbol)
                        .font(scale.meta.font(weight: .regular))
                        .foregroundStyle(glyphColor)
                        .accessibilityHidden(true)
                }
                if let icon = items.first(where: { $0.id == selectedId })?.icon {
                    Self.iconView(icon, symbolFont: scale.glyphFont, accent: glyphColor)
                }
                Text(label.isEmpty ? placeholder : label)
                    .font(scale.meta.font(weight: .medium))
                    .foregroundStyle(isNeutral ? theme.color("fg-muted") : Self.labelForeground(accent: accent, theme: theme))
                    .lineLimit(1)
                if fillsWidth { Spacer(minLength: 0) }
                Image(systemName: "chevron.down")
                    .font(scale.glyph.font(weight: .bold))
                    .foregroundStyle(glyphColor)
            }
            .padding(.horizontal, scale.space[2])
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: scale.radius.medium)
                    .fill(isNeutral ? theme.color("bg-3").opacity(0.7) : accent.opacity(0.18))
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
            .environment(\.designScale, scale)
        }
    }

    private var glyphColor: Color { isNeutral ? theme.color("fg-muted") : accent }

    @ViewBuilder
    static func iconView(_ icon: Icon, symbolFont: Font, accent: Color) -> some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(symbolFont)
                .foregroundStyle(accent)
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
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

        let chipBackground = Color.composited(accent, alpha: 0.18, over: theme.color("bg-1"))
        let minimumContrast = 4.5
        let preferredBlend = Color.blend(accent, .black, t: 0.30)
        if Color.contrastRatio(preferredBlend, chipBackground) >= minimumContrast {
            return preferredBlend
        }

        var lower = 0.30
        var upper = 1.0
        for _ in 0..<12 {
            let midpoint = (lower + upper) / 2
            let candidate = Color.blend(accent, .black, t: midpoint)
            if Color.contrastRatio(candidate, chipBackground) >= minimumContrast {
                upper = midpoint
            } else {
                lower = midpoint
            }
        }
        return Color.blend(accent, .black, t: upper)
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
    @Environment(\.designScale) private var scale
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
        let matches = ACPSelectChip.filteredItems(
            items,
            query: query,
            searchDescriptions: searchDescriptions,
            searchIdentifiers: searchIdentifiers
        )
        // Item ids come from agent-supplied model/mode/option lists that
        // aren't validated upstream. Drop duplicate ids so the row `.id()`
        // and ForEach identity stay unique — duplicate SwiftUI list ids are
        // undefined behavior.
        var seen = Set<String>()
        return matches.filter { seen.insert($0.id).inserted }
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
                                .font(scale.metaFont)
                                .foregroundStyle(theme.color("fg-faint"))
                                .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[3])
                        }
                    }
                    .padding(.vertical, scale.space[1])
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
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-faint"))
            TextField("Search…", text: $query)
                .textFieldStyle(.plain)
                .font(scale.metaFont)
                .focused($searchFocused)
                .onChange(of: query) { _, _ in highlight = 0 }
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
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
                        if let icon = item.icon {
                            ACPSelectChip.iconView(icon, symbolFont: scale.caption.font(weight: .semibold), accent: accent)
                        }
                        Text(item.name)
                            .font(scale.body.font(weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(theme.color("fg"))
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(scale.glyph.font(weight: .bold))
                                .foregroundStyle(accent)
                        }
                        if let badge = item.badge {
                            Text(badge)
                                .font(scale.caption.font(weight: .regular))
                                .foregroundStyle(theme.color("fg-faint"))
                        }
                    }
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc)
                            .font(scale.caption.font(weight: .regular))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
            .background(rowBg(isHighlighted: isHighlighted, isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
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
