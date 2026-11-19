import AlasCore
import SwiftUI

/// The Devices tab's toolbar chip: the selected device and its state. It
/// opens a popover listing running devices first, then the Mac's simulators
/// by runtime, Android devices and this worktree's VMs.
struct DevicesSwitcher: View {
    let state: DevicesTabState
    let onSelect: (DevicesTarget) -> Void
    /// Boots a shut-down simulator or AVD; it is selected first.
    let onBoot: (DevicesTarget) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    @State private var hovering = false
    @State private var showsPopover = false

    var body: some View {
        let selected = state.selectedRow
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.color(DeviceStyle.colorToken(selected?.tone ?? .idle)))
                    .frame(width: 8, height: 8)
                Text(selected?.title ?? "Devices")
                    .font(scale.meta.font(weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    // The status truncates first when the pane is narrow.
                    .layoutPriority(1)
                if let status = selected?.status, !status.isEmpty {
                    Text(status)
                        .font(scale.meta.font)
                        .foregroundStyle(theme.color("fg-dim"))
                }
                Image(systemName: "chevron.down")
                    .font(scale.glyphFont)
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .lineLimit(1)
            .padding(.horizontal, scale.space[2])
            .frame(height: 22)
            .background(hovering ? theme.color("bg-3") : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.toolbarControl)
        // Not horizontally fixed: next to the fixed-size device actions a
        // full-width chip overflows a narrow pane, so it truncates instead.
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
        .help("Choose a device")
        .accessibilityIdentifier("devices-switcher")
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            DevicesSwitcherPanel(
                state: state,
                onSelect: { target in
                    onSelect(target)
                    showsPopover = false
                },
                onBoot: { target in
                    onSelect(target)
                    onBoot(target)
                    showsPopover = false
                },
                onClose: { showsPopover = false }
            )
            .environment(\.theme, theme)
            .environment(\.designScale, scale)
        }
    }
}

/// The switcher's popover: a filter field over the sectioned device list,
/// with arrow-key navigation and an inline Boot on shut-down rows. Modeled on
/// `ACPSelectChip`'s dropdown.
struct DevicesSwitcherPanel: View {
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
            // Start at the selected device, so arrows move from where the user is.
            if highlight == nil, let selected = state.selected, rows.contains(where: { $0.target == selected }) {
                highlight = selected
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
        let isSelected = row.target == state.selected
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

/// The Devices tab's toolbar actions for a simulator: its logs and settings,
/// a screen recording and a screenshot to the Desktop, and Shut Down.
struct DevicesActions: View {
    let device: SimulatorDevice
    let booted: Bool
    let client: SimulatorStreamClient
    let control: DeviceAgentControl
    /// Booted, and no agent drives it.
    let canChangeSettings: Bool
    let onShutDown: () -> Void
    let onOpenLogs: () -> Void
    let accessibilityOverlay: Bool
    let onToggleAccessibilityOverlay: () -> Void
    let recorder: DeviceRecorder
    /// Names the agent session recording the device.
    let agentName: (String) -> String
    let flowRecorder: DeviceFlowRecorder
    let worktree: URL
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    /// "Saved to Desktop", or why it wasn't, for a moment after a click.
    @State private var notice: String?
    @State private var showsSettings = false

    var body: some View {
        HStack(spacing: 2) {
            if let notice {
                Text(notice)
                    .font(scale.caption.font(weight: .regular))
                    .foregroundStyle(theme.color("fg-dim"))
                    .lineLimit(1)
                    .transition(.opacity)
                    .task(id: notice) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { self.notice = nil }
                    }
            }
            ToolbarBtn(icon: "doc.text.magnifyingglass", tooltip: "Logs", action: onOpenLogs)
                .disabled(!booted)
            ToolbarBtn(
                icon: "accessibility",
                tooltip: accessibilityOverlay ? "Hide accessibility overlay" : "Show accessibility overlay",
                isActive: accessibilityOverlay, action: onToggleAccessibilityOverlay
            )
            .disabled(!booted)
            ToolbarBtn(icon: "slider.horizontal.3", tooltip: "Simulator settings") { showsSettings = true }
                .disabled(!canChangeSettings)
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                    if let backend = control.backend(for: .ios) {
                        DeviceSettingsPopover(udid: device.udid, backend: backend, control: control)
                    }
                }
            DeviceFlowButtons(
                udid: device.udid, backend: control.backend(for: .ios), control: control, recorder: flowRecorder,
                worktree: worktree, enabled: canChangeSettings
            )
            recordButton
            ToolbarBtn(icon: "camera", tooltip: "Save screenshot to Desktop", action: saveScreenshot)
                .disabled(!booted)
            ToolbarMenuButton(iconName: "ellipsis", help: "More") {
                Button("Shut Down", action: onShutDown)
                    .disabled(!booted)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var recordButton: some View {
        switch recorder.owner(udid: device.udid) {
        case nil:
            ToolbarBtn(icon: "record.circle", tooltip: "Record screen") {
                do throws(DeviceRecorder.Failure) {
                    try recorder.start(udid: device.udid, owner: .user, file: Self.userRecordingFile())
                } catch {
                    withAnimation { notice = "Couldn't start recording" }
                }
            }
            .disabled(!booted)
        case .user:
            ToolbarBtn(icon: "stop.circle.fill", tooltip: "Stop recording", isActive: true) {
                Task { await stopRecording() }
            }
        case .agent(let sessionID):
            ToolbarBtn(icon: "record.circle", tooltip: "\(agentName(sessionID)) is recording", isActive: true) {}
                .disabled(true)
        }
    }

    /// A temporary file; stopping moves it to the Desktop.
    private static func userRecordingFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("alas-recording-\(UUID().uuidString).mov")
    }

    private func stopRecording() async {
        let text: String
        do {
            // The recorder saves it to the Desktop (AppState's onUserRecordingEnded).
            _ = try await recorder.stop(udid: device.udid, owner: .user)
            text = "Saved to Desktop"
        } catch DeviceRecorder.Failure.notSaved {
            text = "Couldn't save to the Desktop; it's shown in Finder"
        } catch {
            text = "Couldn't save the recording"
        }
        withAnimation { notice = text }
    }

    private func saveScreenshot() {
        let text: String
        if let frame = client.lastFrame(udid: device.udid) {
            do {
                _ = try DeviceScreenshot.saveToDesktop(frame, deviceName: device.name)
                text = "Saved to Desktop"
            } catch {
                text = "Couldn't save the screenshot"
            }
        } else {
            text = "No frame yet"
        }
        withAnimation { notice = text }
    }
}
