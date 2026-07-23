import AppKit
import SwiftUI

struct ImageDiffView: View {
    let pair: ImageDiffPair
    let relativePath: String
    let onOpenFile: (() -> Void)?

    @State private var mode: ImageDiffMode = .sideBySide
    @State private var percentChanged: Double?
    @State private var transform = ImageDiffTransform()
    @Environment(\.theme) private var theme

    /// Pure helper exposed for testing. If the currently-selected mode is
    /// not applicable for `pair`, snap to `.sideBySide`.
    static func snapToApplicableMode(_ mode: inout ImageDiffMode,
                                     for pair: ImageDiffPair) {
        if !mode.isApplicable(for: pair) {
            mode = .sideBySide
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.color("bg-1"))
        .onAppear { Self.snapToApplicableMode(&mode, for: pair) }
        .onChange(of: mode) { _, _ in
            // Bouncing back when user attempts a disabled mode is enforced
            // by the segmented control disabling itself; this is a belt-
            // and-suspenders check.
            Self.snapToApplicableMode(&mode, for: pair)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text((relativePath as NSString).lastPathComponent)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(theme.color("fg"))
            Text("·").foregroundColor(theme.color("fg-faint"))
            Text((relativePath as NSString).deletingLastPathComponent)
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
            if pair.kind == .renamed, let old = pair.oldPath {
                pathChangeChip(kind: "RENAMED", old: old, new: relativePath)
            }
            if pair.kind == .copied, let old = pair.oldPath {
                pathChangeChip(kind: "COPIED", old: old, new: relativePath)
            }
            if mode == .difference, let pct = percentChanged {
                changedChip(percent: pct)
            }
            if pair.beforeFrameCount > 1 || pair.afterFrameCount > 1 {
                Text("first frame only")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(theme.color("warn").opacity(0.18))
                    .foregroundColor(theme.color("warn"))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer()
            modeSwitcher
            if mode == .sideBySide {
                resetButton
            }
            if let onOpenFile {
                AlasButton(title: "Open File", style: .subtle, action: onOpenFile)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    @ViewBuilder
    private func pathChangeChip(kind: String, old: String, new: String) -> some View {
        let oldName = (old as NSString).lastPathComponent
        let newName = (new as NSString).lastPathComponent
        Text("\(kind) \(oldName) → \(newName)")
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(theme.color("info").opacity(0.18))
            .foregroundColor(theme.color("info"))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    @ViewBuilder
    private func changedChip(percent: Double) -> some View {
        let pct = String(format: "%.1f%%", percent)
        Text("\(pct) changed")
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(red: 0.96, green: 0.45, blue: 0.71).opacity(0.18))
            .foregroundColor(Color(red: 0.96, green: 0.45, blue: 0.71))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(ImageDiffMode.allCases, id: \.self) { m in
                modeButton(m)
            }
        }
        .padding(2)
        .background(theme.color("seg-container-bg"))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color("line"), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var resetButton: some View {
        Button {
            transform.reset()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
                .foregroundColor(theme.color("fg-muted"))
        }
        .buttonStyle(.plain)
        .help("Reset zoom")
        .disabled(transform == .init())
    }

    @ViewBuilder
    private func modeButton(_ m: ImageDiffMode) -> some View {
        let enabled = m.isApplicable(for: pair)
        let isOn = mode == m && enabled
        Button {
            if enabled { mode = m }
        } label: {
            Image(systemName: m.systemImageName)
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .contentShape(Rectangle())
                .background(
                    ZStack {
                        if isOn {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(theme.color("bg-3"))
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                                .blendMode(.plusLighter)
                        }
                    }
                )
                .foregroundColor(
                    enabled
                        ? (isOn ? theme.color("fg") : theme.color("fg-muted"))
                        : theme.color("fg-faint")
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: isOn ? Color.black.opacity(0.25) : .clear, radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? m.displayName : "\(m.displayName) — not applicable")
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .sideBySide:
            ImageDiffSideBySideView(
                before: pair.beforeImage, after: pair.afterImage,
                beforeLabel: "Before", afterLabel: "After",
                transform: $transform
            )
        case .overlay:
            if let b = pair.beforeImage, let a = pair.afterImage {
                ImageDiffOverlayView(before: b, after: a)
            } else {
                Color.clear
            }
        case .swipe:
            if let b = pair.beforeImage, let a = pair.afterImage {
                ImageDiffSwipeView(before: b, after: a)
            } else {
                Color.clear
            }
        case .difference:
            if let b = pair.beforeImage, let a = pair.afterImage {
                ImageDiffDifferenceView(
                    before: b, after: a, percentChanged: $percentChanged
                )
            } else {
                Color.clear
            }
        }
    }
}
