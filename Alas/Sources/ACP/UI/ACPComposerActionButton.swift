import Foundation
import SwiftUI

/// Single state-driven button that replaces the composer's separate Send
/// and Stop affordances. Pure render of a `ComposerAction` — knows nothing
/// about `ACPSession` or the runner. The shell wires `onPrimary` / `onMenu`
/// to the appropriate `submitWithIntent` / `userCancel` calls.
struct ACPComposerActionButton: View {
    let action: ComposerAction
    let onPrimary: () -> Void
    let onMenu: (ComposerMenuItem) -> Void
    let onSchedule: (Date) -> Void
    let queueBadgeCount: Int

    @Environment(\.theme) private var theme
    @State private var customScheduleDate = Date()
    @State private var showsCustomSchedule = false

    var body: some View {
        switch action {
        case .hidden:
            EmptyView()
        case .send:
            sendCapsule
        case .stop:
            stopCapsule
        case .queue(let menu):
            queueSplitCapsule(menu: menu)
        }
    }

    // MARK: - Send (split capsule, accent-colored)

    private var sendCapsule: some View {
        HStack(spacing: 0) {
            Button(action: onPrimary) {
                primaryHalf(
                    title: "Send",
                    // `line` is a neutral hairline meant for neutral fills; on the
                    // accent half it disappears. Tint the foreground color instead.
                    divider: theme.color("bg-0")
                        .opacity(ACPComposerActionButtonMetrics.dividerOnAccentOpacity)
                )
            }
            .buttonStyle(.plain)
            .help("Send (⏎)")

            chevronHalf(help: "Schedule send") {
                let now = Date()
                ForEach(ACPSchedulePreset.allCases) { preset in
                    if preset.date(after: now) != nil {
                        Button(preset.title) {
                            if let date = preset.date(after: Date()) { onSchedule(date) }
                        }
                    }
                }
                Divider()
                Button("Custom date and time…") {
                    let now = Date()
                    customScheduleDate = ACPSchedulePreset.laterToday.date(after: now)
                        ?? ACPSchedulePreset.tomorrowMorning.date(after: now)!
                    showsCustomSchedule = true
                }
            }
        }
        .capsuleSurface(
            foreground: theme.color("bg-0"),
            fill: theme.color("accent")
        )
        .popover(isPresented: $showsCustomSchedule) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Schedule message")
                    .font(.headline)
                DatePicker(
                    "Send at",
                    selection: $customScheduleDate,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
                HStack {
                    Spacer()
                    Button("Cancel") { showsCustomSchedule = false }
                    Button("Schedule") {
                        if customScheduleDate > Date() {
                            onSchedule(customScheduleDate)
                            showsCustomSchedule = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customScheduleDate <= Date())
                }
            }
            .padding(16)
            .frame(width: 320)
        }
    }

    // MARK: - Stop (single capsule, destructive treatment)

    private var stopCapsule: some View {
        Button(action: onPrimary) {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .bold))
                Text("Stop")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(theme.color("del"))
            .padding(.horizontal, 11)
            .frame(height: ACPComposerActionButtonMetrics.capsuleHeight)
            .background(
                RoundedRectangle(cornerRadius: ACPComposerActionButtonMetrics.cornerRadius)
                    .fill(theme.color("del").opacity(0.15))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ACPComposerActionButtonMetrics.cornerRadius)
                    .strokeBorder(theme.color("del").opacity(0.45), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help("Stop the running turn (Esc)")
    }

    // MARK: - Queue (split capsule, primary + chevron menu)

    private func queueSplitCapsule(menu: [ComposerMenuItem]) -> some View {
        HStack(spacing: 0) {
            Button(action: onPrimary) {
                primaryHalf(title: "Queue", divider: theme.color("line"))
            }
            .buttonStyle(.plain)
            .help("Queue (⏎). Hold ⌥ to steer.")

            chevronHalf(help: "More actions") {
                ForEach(menu, id: \.self) { item in
                    menuButton(for: item)
                    if item == .steer, menu.contains(.stop) {
                        Divider()
                    }
                }
            }
        }
        .capsuleSurface(
            foreground: theme.color("fg"),
            fill: theme.color("bg-3")
        )
        .overlay(
            RoundedRectangle(cornerRadius: ACPComposerActionButtonMetrics.cornerRadius)
                .strokeBorder(theme.color("line"), lineWidth: 1)
        )
    }

    // MARK: - Split-capsule halves

    /// Primary half: icon + title, the hairline marking the split, and the
    /// queue badge. It paints no fill of its own — the capsule draws one
    /// background behind both halves (see `capsuleSurface`), so the two can't
    /// disagree about height, radius or color.
    private func primaryHalf(title: String, divider: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
        }
        .padding(.horizontal, 11)
        .frame(height: ACPComposerActionButtonMetrics.capsuleHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .trailing) { segmentDivider(divider) }
        .overlay(alignment: .topTrailing) { badgeOverlay }
    }

    /// Chevron half: the menu affordance at the trailing end of the capsule.
    ///
    /// `.button` + `.plain`, deliberately not `.borderlessButton`. The
    /// borderless style hands the label to an `NSPopUpButton`, which draws the
    /// glyph in its own label color and sizes itself to the label's intrinsic
    /// ~14pt no matter what frame the label carries. That gave us three bugs at
    /// once: a chevron tinted differently from the title, a segment background
    /// shorter than the primary half, and 6pt of dead space at the top and
    /// bottom of the segment where clicks missed the menu. `.button` keeps the
    /// label in SwiftUI, where the frame and the inherited foreground style
    /// both apply.
    private func chevronHalf<Content: View>(
        help: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu {
            content()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, ACPComposerActionButtonMetrics.chevronHorizontalPadding)
                .frame(height: ACPComposerActionButtonMetrics.capsuleHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }

    // MARK: - Segment divider (hairline between the primary half and the chevron)

    /// Inset hairline drawn on the trailing edge of the primary half. Both
    /// halves share one background, so this divider is the only thing marking
    /// the split.
    private func segmentDivider(_ color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(
                width: ACPComposerActionButtonMetrics.dividerWidth,
                height: ACPComposerActionButtonMetrics.dividerHeight
            )
    }

    @ViewBuilder
    private func menuButton(for item: ComposerMenuItem) -> some View {
        switch item {
        case .steer:
            Button {
                onMenu(.steer)
            } label: {
                Label("Steer running turn (⌥⏎)", systemImage: "arrow.turn.up.right")
            }
        case .stop:
            Button(role: .destructive) {
                onMenu(.stop)
            } label: {
                Label("Stop running turn (Esc)", systemImage: "stop.fill")
            }
        }
    }

    // MARK: - Queue count badge (rendered on Send & Queue primary halves)

    @ViewBuilder
    private var badgeOverlay: some View {
        if queueBadgeCount > 0 {
            Text("\(queueBadgeCount)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.color("bg-0"))
                .padding(.horizontal, 4)
                .frame(
                    minWidth: ACPComposerActionButtonMetrics.badgeMinWidth,
                    minHeight: ACPComposerActionButtonMetrics.badgeMinHeight
                )
                .background(Capsule().fill(theme.color("warn")))
                .overlay(Capsule().strokeBorder(theme.color("bg-0"), lineWidth: 1))
                .offset(ACPComposerActionButtonMetrics.badgeOffset)
                .allowsHitTesting(false)
        }
    }
}

private extension View {
    /// Paints a split capsule as one surface: a single fill behind both halves
    /// and a single foreground style inherited by both. Neither half carries a
    /// background or a color of its own, so they cannot drift out of alignment
    /// or out of tint.
    func capsuleSurface(foreground: Color, fill: Color) -> some View {
        foregroundStyle(foreground)
            .frame(height: ACPComposerActionButtonMetrics.capsuleHeight)
            .background(
                fill,
                in: RoundedRectangle(cornerRadius: ACPComposerActionButtonMetrics.cornerRadius)
            )
    }
}

enum ACPComposerActionButtonMetrics {
    static let capsuleHeight: CGFloat = 26
    static let cornerRadius: CGFloat = 7
    static let chevronHorizontalPadding: CGFloat = 7
    static let badgeMinWidth: CGFloat = 16
    static let badgeMinHeight: CGFloat = 14
    static let badgeOffset = CGSize(width: 6, height: -6)
    static let dividerWidth: CGFloat = 1
    static let dividerHeight: CGFloat = 16
    static let dividerOnAccentOpacity: Double = 0.35

    static var badgeTopOutset: CGFloat {
        max(0, -badgeOffset.height)
    }
}
