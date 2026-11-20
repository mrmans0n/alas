import AlasCore
import SwiftUI

/// The Devices rail's + Add popover: a filter field over the sectioned device
/// list, with arrow-key navigation and an inline Boot on shut-down rows.
/// Modeled on `ACPSelectChip`'s dropdown.
struct DevicesAddPanel: View {
    let state: DevicesTabState
    let onSelect: (DevicesTarget) -> Void
    let onBoot: (DevicesTarget) -> Void
    let onClose: () -> Void

    /// `query` and `hovered` seed the panel for design captures.
    init(
        state: DevicesTabState, query: String = "", hovered: DevicesTarget? = nil,
        onSelect: @escaping (DevicesTarget) -> Void, onBoot: @escaping (DevicesTarget) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.state = state
        self.onSelect = onSelect
        self.onBoot = onBoot
        self.onClose = onClose
        _query = State(initialValue: query)
        _highlight = State(initialValue: hovered)
        _hoveredTarget = State(initialValue: hovered)
    }

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var query = ""
    @State private var showsOlderRuntimes = false
    /// The highlighted row; nil or a row that's gone means the first row.
    /// Keyed by device, so rows shifting under it don't move it.
    @State private var highlight: DevicesTarget?
    /// The row under the mouse; only it shows the inline Boot.
    @State private var hoveredTarget: DevicesTarget?
    /// Bumps only on keyboard navigation, so hovering a row tints it without
    /// scrolling the list under the cursor.
    @State private var keyboardScrollTick = 0
    @FocusState private var filterFocused: Bool

    var body: some View {
        let listing = state.switcherListing(query: query, showsOlderRuntimes: showsOlderRuntimes)
        let rows = listing.sections.flatMap(\.rows)
        let current = rows.firstIndex { $0.target == highlight } ?? 0
        let highlighted = rows.indices.contains(current) ? rows[current].target : nil
        let lastRuntime = listing.sections.last {
            if case .runtime = $0.kind { true } else { false }
        }?.id
        VStack(spacing: 0) {
            filterBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(listing.sections) { section in
                            sectionView(section, highlighted: highlighted)
                            // Right under the simulators it unfolds, not below Android and VMs.
                            if listing.foldedRuntimeCount > 0, section.id == lastRuntime {
                                olderRuntimesButton(count: listing.foldedRuntimeCount)
                            }
                        }
                        if listing.sections.isEmpty {
                            // Empty without a query: the simulator list is still loading.
                            Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "Looking for devices…" : "No matches")
                                .font(scale.metaFont)
                                .foregroundStyle(theme.color("fg-faint"))
                                .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[3])
                        }
                    }
                    .padding(.vertical, scale.space[1])
                    .padding(.horizontal, scale.space[1])
                }
                .onChange(of: keyboardScrollTick) { _, _ in
                    guard let highlighted else { return }
                    withAnimation(.easeOut(duration: 0.10)) {
                        proxy.scrollTo(highlighted, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 300)
        .frame(maxHeight: 360)
        .background(theme.color("bg-1"))
        .onKeyPress { press in
            switch press.key {
            case .upArrow:
                if !rows.isEmpty { highlight = rows[max(0, current - 1)].target }
                keyboardScrollTick &+= 1
                return .handled
            case .downArrow:
                if !rows.isEmpty { highlight = rows[min(rows.count - 1, current + 1)].target }
                keyboardScrollTick &+= 1
                return .handled
            case .return:
                if let highlighted {
                    onSelect(highlighted)
                }
                return .handled
            default:
                return .ignored
            }
        }
        .onExitCommand(perform: onClose)
        .onAppear {
            filterFocused = true
            // Start at the last-used device, so arrows move from where the user is.
            if highlight == nil, let lastUsed = state.lastUsed, rows.contains(where: { $0.target == lastUsed }) {
                highlight = lastUsed
                keyboardScrollTick &+= 1
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-faint"))
            TextField("Filter devices", text: $query)
                .textFieldStyle(.plain)
                .font(scale.metaFont)
                .focused($filterFocused)
                .onChange(of: query) { _, _ in highlight = nil }
        }
        .padding(.horizontal, scale.space[3]).padding(.vertical, scale.space[2])
        .background(theme.color("bg-0").opacity(0.6))
    }

    @ViewBuilder
    private func sectionView(_ section: DevicesSwitcherSection, highlighted: DevicesTarget?) -> some View {
        Text(section.title)
            .font(scale.captionFont)
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, scale.space[2])
            .padding(.top, scale.space[2])
            .padding(.bottom, 2)
        if let note = section.note {
            Text(note)
                .font(scale.caption.font(weight: .regular))
                .foregroundStyle(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, scale.space[2])
                .padding(.vertical, 2)
        }
        ForEach(section.rows) { row in
            rowView(row, isHighlighted: row.target == highlighted, running: section.kind == .running)
                // Data-based id, so filtering doesn't freeze LazyVStack rows.
                .id(row.id)
        }
    }

    /// The text after a row's name: the runtime for a running device that is
    /// simply booted, otherwise its state.
    private static func trailing(_ row: DevicesTabState.Row, running: Bool) -> String {
        running && row.tone != .busy ? row.detail : row.status
    }

    @ViewBuilder
    private func rowView(_ row: DevicesTabState.Row, isHighlighted: Bool, running: Bool) -> some View {
        let isSelected = row.target == state.lastUsed
        let showsBoot = hoveredTarget == row.target && row.canBoot
        HStack(spacing: 0) {
            Button { onSelect(row.target) } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.color(DeviceStyle.colorToken(row.tone)))
                        .frame(width: 8, height: 8)
                    Image(systemName: DeviceStyle.glyph(row.platform))
                        .font(scale.glyphFont)
                        .foregroundStyle(theme.color("fg-muted"))
                        .frame(width: 14)
                    Text(row.title)
                        .font(scale.body.font(weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(theme.color("fg"))
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if !showsBoot {
                        Text(Self.trailing(row, running: running))
                            .font(scale.caption.font(weight: .regular))
                            .foregroundStyle(theme.color("fg-dim"))
                    }
                }
                .lineLimit(1)
                .padding(.leading, scale.space[2])
                .padding(.trailing, showsBoot ? 6 : scale.space[2])
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsBoot {
                Button { onBoot(row.target) } label: {
                    Text("Boot")
                        .font(scale.caption.font(weight: .semibold))
                        .foregroundStyle(theme.color("accent"))
                        .padding(.horizontal, scale.space[2])
                        .frame(height: 18)
                        .background(theme.color("accent").opacity(0.15), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.toolbarControl)
                .help("Boot \(row.title)")
                .padding(.trailing, scale.space[2])
            }
        }
        .background(rowBackground(isHighlighted: isHighlighted, isSelected: isSelected))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
        .onHover { hovering in
            if hovering {
                highlight = row.target
                hoveredTarget = row.target
            } else if hoveredTarget == row.target {
                hoveredTarget = nil
            }
        }
    }

    private func olderRuntimesButton(count: Int) -> some View {
        Button {
            showsOlderRuntimes = true
        } label: {
            Text("Show \(count) older runtime\(count == 1 ? "" : "s")")
                .font(scale.caption.font(weight: .medium))
                .foregroundStyle(theme.color("accent"))
                .padding(.horizontal, scale.space[2])
                .padding(.vertical, scale.space[2])
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(isHighlighted: Bool, isSelected: Bool) -> Color {
        if isHighlighted { return theme.color("accent").opacity(0.15) }
        if isSelected { return theme.color("accent").opacity(0.07) }
        return .clear
    }
}
