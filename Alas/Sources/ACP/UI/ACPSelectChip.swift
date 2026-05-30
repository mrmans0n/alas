import SwiftUI

/// Styled chip + custom popover dropdown used for the composer's model and
/// mode pickers. Shows a colored dot, label, and chevron; tapping opens a
/// popover with optional search (auto-shown when items > 5) and a list of
/// rows. Mirrors the design's `chat-model` button visual.
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
            HStack(spacing: 5) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .shadow(color: accent.opacity(0.7), radius: 3)
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
                onSelect: { item in
                    onSelect(item)
                    showPopover = false
                }
            )
            .environment(\.theme, theme)
        }
    }

    static func labelForeground(accent: Color, theme: Theme) -> Color {
        Color.blend(accent, theme.darkMode ? .white : .black, t: theme.darkMode ? 0.55 : 0.30)
    }
}

/// Popover content: optional search field + scrollable list.
private struct DropdownPanel: View {
    let items: [ACPSelectChip.Item]
    let selectedId: String?
    let accent: Color
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return items }
        return items.filter {
            $0.name.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
                || ($0.description?.lowercased().contains(q) ?? false)
        }
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
                                .id(idx)
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
                    withAnimation(.easeOut(duration: 0.10)) {
                        proxy.scrollTo(highlight, anchor: .center)
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
