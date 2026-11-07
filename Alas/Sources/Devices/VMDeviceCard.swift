import AlasCore
import SwiftUI

/// A worktree VM in the Devices tab. Its screen lives in a center tab, so the
/// card says where it stands and opens it.
struct VMDeviceCard: View {
    let guest: VMGuestOS
    let status: VMDeviceStatus
    /// Who drives it while it runs.
    let driver: VMDriverStatus?
    let now: Date
    let onOpen: () -> Void
    let onTakeOver: () -> Void
    let onHandBack: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: guest == .macOS ? "desktopcomputer" : "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(theme.color("fg-muted"))
            Text(guest == .macOS ? "macOS VM" : "Linux VM")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            Text(stateLine)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.color("fg-dim"))
            if let driver, status == .running {
                VStack(spacing: 2) {
                    Text(driver.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(theme.color(driver.tone.colorToken))
                    ForEach(driver.details, id: \.self) { detail in
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.color("fg-faint"))
                    }
                }
            }
            HStack(spacing: 8) {
                if case .runningElsewhere = status {
                    EmptyView()
                } else {
                    AlasButton(title: status == .notCreated ? "Set up" : "Open", style: .primary, action: onOpen)
                }
                if let driver, status == .running {
                    switch driver.action {
                    case .takeOver: AlasButton(title: "Take over", action: onTakeOver)
                    case .handBack: AlasButton(title: "Hand back", action: onHandBack)
                    }
                }
            }
            .padding(.top, 4)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(width: 260)
        .background(theme.color("bg-2"), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color("line"), lineWidth: 0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stateLine: String {
        switch status {
        case .notCreated: "Not set up for this worktree"
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .running: "Running"
        case .pausing: "Saving its state…"
        case .paused(let savedAt):
            "Paused, saved \(RelativeDateTimeFormatter().localizedString(for: savedAt, relativeTo: now))"
        case .runningElsewhere(let label): "Running in \(label)"
        }
    }
}
