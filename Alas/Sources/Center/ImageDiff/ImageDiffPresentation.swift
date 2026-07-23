import Observation
import SwiftUI

struct ImageDiffPairPresentationIdentity: Equatable {
    private enum Side: Equatable {
        case image(ObjectIdentifier, Int)
        case missing
        case failed(String)

        init(_ side: ImageDiffSide) {
            switch side {
            case .image(let image, let frameCount):
                self = .image(ObjectIdentifier(image), frameCount)
            case .missing:
                self = .missing
            case .failed(let failure):
                self = .failed(failure.message)
            }
        }
    }

    private let relativePath: String
    private let oldPath: String?
    private let kind: ImageDiffPairKind
    private let before: Side
    private let after: Side

    init(pair: ImageDiffPair, relativePath: String) {
        self.relativePath = relativePath
        self.oldPath = pair.oldPath
        self.kind = pair.kind
        self.before = Side(pair.before)
        self.after = Side(pair.after)
    }
}

@Observable
@MainActor
final class ImageDiffPresentationState {
    var mode: ImageDiffMode = .sideBySide
    var percentChanged: Double?
    var transform = ImageDiffTransform()
    @ObservationIgnored private var displayedPairIdentity: ImageDiffPairPresentationIdentity?

    func updateDisplayedPair(
        _ pair: ImageDiffPair,
        identity: ImageDiffPairPresentationIdentity
    ) {
        defer {
            displayedPairIdentity = identity
            snapToApplicableMode(for: pair)
        }

        if let displayedPairIdentity, displayedPairIdentity != identity {
            resetForNewPair()
        }
    }

    func resetForNewPair() {
        mode = .sideBySide
        percentChanged = nil
        transform = ImageDiffTransform()
    }

    func snapToApplicableMode(for pair: ImageDiffPair) {
        if !mode.isApplicable(for: pair) {
            mode = .sideBySide
        }
    }
}

struct ImageDiffControls: View {
    let pair: ImageDiffPair
    @Bindable var state: ImageDiffPresentationState
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            if state.mode == .difference, let percentChanged = state.percentChanged {
                changedChip(percent: percentChanged)
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
            if state.mode == .sideBySide {
                resetButton
            }
        }
    }

    private func changedChip(percent: Double) -> some View {
        let percent = String(format: "%.1f%%", percent)
        return Text("\(percent) changed")
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(red: 0.96, green: 0.45, blue: 0.71).opacity(0.18))
            .foregroundColor(Color(red: 0.96, green: 0.45, blue: 0.71))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(ImageDiffMode.allCases, id: \.self) { mode in
                modeButton(mode)
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
            state.transform.reset()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
                .foregroundColor(theme.color("fg-muted"))
        }
        .buttonStyle(.plain)
        .help("Reset zoom")
        .disabled(state.transform == .init())
    }

    private func modeButton(_ mode: ImageDiffMode) -> some View {
        let enabled = mode.isApplicable(for: pair)
        let isOn = state.mode == mode && enabled
        return Button {
            if enabled {
                state.mode = mode
            }
        } label: {
            Image(systemName: mode.systemImageName)
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
        .help(enabled ? mode.displayName : "\(mode.displayName) — not applicable")
    }
}

struct ImageDiffComparisonContent: View {
    let pair: ImageDiffPair
    @Bindable var state: ImageDiffPresentationState
    var boundedHeight: CGFloat? = nil

    var body: some View {
        Group {
            switch state.mode {
            case .sideBySide:
                ImageDiffSideBySideView(
                    before: pair.before,
                    after: pair.after,
                    beforeLabel: "Before",
                    afterLabel: "After",
                    transform: $state.transform
                )
            case .overlay:
                if let before = pair.beforeImage, let after = pair.afterImage {
                    ImageDiffOverlayView(before: before, after: after)
                } else {
                    Color.clear
                }
            case .swipe:
                if let before = pair.beforeImage, let after = pair.afterImage {
                    ImageDiffSwipeView(before: before, after: after)
                } else {
                    Color.clear
                }
            case .difference:
                if let before = pair.beforeImage, let after = pair.afterImage {
                    ImageDiffDifferenceView(
                        before: before,
                        after: after,
                        percentChanged: $state.percentChanged
                    )
                } else {
                    Color.clear
                }
            }
        }
        .frame(height: boundedHeight)
    }
}
