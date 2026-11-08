import SwiftUI

/// Model, thinking, mode, parameter, fast-mode and boolean-option controls
/// shared by the local composer and the peer composer. Selection goes through
/// closures so each host decides how a change is routed.
@MainActor
struct ACPComposerChips {
    let theme: Theme
    let scale: DesignScale
    let chipState: ACPChipState
    let configOptions: [ACPConfigOption]
    let onSelect: (ChipSpec, String) -> Void
    let onConfigValue: (String, ACPConfigValue) -> Void

    @ViewBuilder
    func fastModeToggle() -> some View {
        if let fastMode = fastModeParameter {
            selectFastModeToggle(fastMode)
        } else if let fastMode = fastModeBooleanOption {
            booleanFastModeToggle(fastMode)
        }
    }

    func selectFastModeToggle(_ parameter: ACPParameterChip) -> some View {
        Button {
            guard let targetId = fastModeToggleTarget(for: parameter.spec) else { return }
            onSelect(parameter.spec, targetId)
        } label: {
            fastModeIcon(isEnabled: isFastModeEnabled(parameter.spec))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fast mode")
        .disabled(fastModeToggleTarget(for: parameter.spec) == nil)
        .opacity(fastModeToggleTarget(for: parameter.spec) == nil ? 0.5 : 1.0)
        .help(fastModeHelp(isEnabled: isFastModeEnabled(parameter.spec),
                           canToggle: fastModeToggleTarget(for: parameter.spec) != nil))
    }

    func booleanFastModeToggle(_ option: ACPConfigOption) -> some View {
        let isEnabled = option.currentBoolValue ?? false
        return Button {
            onConfigValue(option.id, .boolean(!isEnabled))
        } label: {
            fastModeIcon(isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Fast mode")
        .help(fastModeHelp(isEnabled: isEnabled, canToggle: true))
    }

    private func fastModeIcon(isEnabled: Bool) -> some View {
        Image(systemName: ACPComposerControlPresentation.fastModeIconName(isEnabled: isEnabled))
            .font(scale.meta.font(weight: .bold))
            .foregroundStyle(fastModeFg(isEnabled: isEnabled))
            .frame(width: 28, height: 24)
            .background(
                RoundedRectangle(cornerRadius: scale.radius.medium).fill(fastModeBg(isEnabled: isEnabled))
            )
    }

    func fastModeHelp(isEnabled: Bool, canToggle: Bool) -> String {
        ACPComposerControlPresentation.fastModeHelp(isEnabled: isEnabled, canToggle: canToggle)
    }

    var fastModeParameter: ACPParameterChip? {
        chipState.parameters.first {
            $0.presentation == .fastMode
                && ACPComposerControlPresentation.canRenderFastModeButton(for: $0.spec)
        }
    }

    var fastModeBooleanOption: ACPConfigOption? {
        configOptions.first {
            $0.type == "boolean"
                && $0.currentBoolValue != nil
                && ACPChipState.isFastModeConfigOption($0)
        }
    }

    var parameterChips: [ACPParameterChip] {
        chipState.parameters.filter {
            $0.presentation != .fastMode
                || !ACPComposerControlPresentation.canRenderFastModeButton(for: $0.spec)
        }
    }

    func fastModeToggleTarget(for spec: ChipSpec) -> String? {
        ACPComposerControlPresentation.fastModeToggleTarget(for: spec)
    }

    func isFastModeEnabled(_ spec: ChipSpec) -> Bool {
        ACPComposerControlPresentation.isFastModeEnabled(spec)
    }

    func fastModeBg(_ spec: ChipSpec) -> Color {
        fastModeBg(isEnabled: isFastModeEnabled(spec))
    }

    func fastModeBg(isEnabled: Bool) -> Color {
        isEnabled
            ? cursorFastAccent.opacity(0.20)
            : theme.color("bg-3").opacity(0.7)
    }

    func fastModeFg(_ spec: ChipSpec) -> Color {
        fastModeFg(isEnabled: isFastModeEnabled(spec))
    }

    func fastModeFg(isEnabled: Bool) -> Color {
        isEnabled
            ? (theme.darkMode
                ? Color.blend(cursorFastAccent, .white, t: 0.45)
                : ACPSelectChip.labelForeground(accent: cursorFastAccent, theme: theme))
            : theme.color("fg-muted")
    }

    // MARK: - Chip builders driven by ACPChipState

    func modeChip(_ spec: ChipSpec) -> some View {
        return chip(spec: spec,
             label: chipLabel(prefix: "Mode", spec: spec),
             placeholder: "Mode",
             // `fullAccess` (bypassPermissions / agent-full-access) bypasses
             // per-action approval, so the chip switches to the warning
             // tint as a passive heads-up. Other non-standard modes keep the
             // accent; an ordinary mode is neutral.
             accent: modeAccent(spec),
             isNeutral: ACPComposerControlPresentation.modeIsNeutral(spec))
    }

    func modeAccent(_ spec: ChipSpec) -> Color {
        ACPComposerControlPresentation.modeUsesWarningTint(spec)
            ? theme.color("warn") : theme.color("accent")
    }

    func thinkingChip(_ spec: ChipSpec) -> some View {
        chip(spec: spec,
             label: selectedName(spec: spec, fallback: "Thinking"),
             placeholder: "Thinking",
             accent: theme.color("accent"),
             leadingSymbol: "brain",
             isNeutral: true)
    }

    func modelChip(_ spec: ChipSpec) -> some View {
        chip(spec: spec,
             label: spec.options.first(where: { $0.id == spec.currentId })?.name
                    ?? spec.currentId
                    ?? "Model",
             placeholder: "Model",
             accent: theme.color("accent"),
             isNeutral: true,
             searchDescriptions: false,
             searchIdentifiers: false)
    }

    @ViewBuilder
    func parameterChip(_ parameter: ACPParameterChip) -> some View {
        switch parameter.presentation {
        case .cursorContextWindow:
            chip(spec: parameter.spec,
                 label: selectedName(spec: parameter.spec, fallback: parameter.label),
                 placeholder: parameter.label,
                 accent: theme.color("accent"),
                 leadingSymbol: "macwindow",
                 isNeutral: true)
        case .fastMode:
            chip(spec: parameter.spec,
                 label: chipLabel(prefix: parameter.label, spec: parameter.spec),
                 placeholder: parameter.label,
                 accent: cursorFastAccent)
        case .standard:
            chip(spec: parameter.spec,
                 label: chipLabel(prefix: parameter.label, spec: parameter.spec),
                 placeholder: parameter.label,
                 accent: theme.color("accent"),
                 isNeutral: true)
        }
    }

    // Cursor's own hue is tuned for dark surfaces; on light the theme's
    // matching status token keeps the chips legible.
    private var cursorFastAccent: Color {
        theme.darkMode ? Color(.sRGB, red: 0.48, green: 0.82, blue: 0.42, opacity: 1) : theme.color("add")
    }

    var booleanConfigOptions: [ACPConfigOption] {
        configOptions.filter {
            $0.type == "boolean" && $0.currentBoolValue != nil
                && !ACPChipState.isFastModeConfigOption($0)
        }
    }

    /// Agent-defined boolean options carry no icon, so they render as a
    /// labelled pill with the same tinted on/off treatment as the fast-mode
    /// and auto-run buttons.
    func booleanConfigToggle(_ option: ACPConfigOption) -> some View {
        let isEnabled = option.currentBoolValue ?? false
        let name = option.name.isEmpty ? option.id : option.name
        return Button {
            onConfigValue(option.id, .boolean(!isEnabled))
        } label: {
            Text(name)
                .font(scale.meta.font(weight: .semibold))
                .foregroundStyle(booleanOptionFg(isEnabled: isEnabled))
                .padding(.horizontal, scale.space[2])
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: scale.radius.medium).fill(booleanOptionBg(isEnabled: isEnabled))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(isEnabled ? "On" : "Off")
        .help("\(name): \(isEnabled ? "on" : "off")")
    }

    func booleanOptionBg(isEnabled: Bool) -> Color {
        isEnabled ? theme.color("accent").opacity(0.20) : theme.color("bg-3").opacity(0.7)
    }

    func booleanOptionFg(isEnabled: Bool) -> Color {
        isEnabled
            ? ACPSelectChip.labelForeground(accent: theme.color("accent"), theme: theme)
            : theme.color("fg-muted")
    }

    func selectedName(spec: ChipSpec, fallback: String) -> String {
        if let id = spec.currentId,
           let item = spec.options.first(where: { $0.id == id }) {
            return item.name
        }
        return spec.currentId ?? fallback
    }

    func chip(spec: ChipSpec,
                      label: String,
                      placeholder: String,
                      accent: Color,
                      leadingSymbol: String? = nil,
                      isNeutral: Bool = false,
                      searchDescriptions: Bool = true,
                      searchIdentifiers: Bool = true,
                      fillsWidth: Bool = false) -> some View {
        ACPSelectChip(
            label: label,
            placeholder: placeholder,
            accent: accent,
            leadingSymbol: leadingSymbol,
            isNeutral: isNeutral,
            items: spec.options.map {
                ACPSelectChip.Item(
                    id: $0.id, name: $0.name, description: $0.description,
                    icon: $0.kind.map { .system($0.iconSystemName) },
                    badge: $0.id == spec.recommendedId ? "Recommended" : nil)
            },
            selectedId: spec.currentId,
            searchDescriptions: searchDescriptions,
            searchIdentifiers: searchIdentifiers,
            fillsWidth: fillsWidth,
            onSelect: { item in onSelect(spec, item.id) }
        )
    }

    /// "Mode: Plan" when a value is selected, "Mode" while pending.
    private func chipLabel(prefix: String, spec: ChipSpec) -> String {
        if let id = spec.currentId,
           let item = spec.options.first(where: { $0.id == id }) {
            return "\(prefix): \(item.name)"
        }
        return prefix
    }
}

/// Auto-run pill visuals: dark accent-tinted fill when active, plain dark when
/// inactive. No glow or filled
/// gradient; that styling diverges from the handoff.
struct ACPAutoRunToggle: View {
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale
    let isEnabled: Bool
    let isDisabled: Bool
    let help: String
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: ACPComposerControlPresentation.autoRunIconName(isEnabled: isEnabled))
                .font(scale.meta.font(weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: scale.radius.medium).fill(background)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto-run")
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
        .help(help)
    }

    private var background: Color { Self.background(isEnabled: isEnabled, theme: theme) }
    private var foreground: Color { Self.foreground(isEnabled: isEnabled, theme: theme) }

    static func background(isEnabled: Bool, theme: Theme) -> Color {
        isEnabled
            ? theme.color("caution").opacity(0.20)
            : theme.color("bg-3").opacity(0.7)
    }

    static func foreground(isEnabled: Bool, theme: Theme) -> Color {
        isEnabled
            ? ACPSelectChip.labelForeground(accent: theme.color("caution"), theme: theme)
            : theme.color("fg-muted")
    }
}
