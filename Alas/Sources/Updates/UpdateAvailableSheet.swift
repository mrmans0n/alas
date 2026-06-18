import AppKit
import SwiftUI

/// Themed sheet shown when a newer release exists. Renders release notes plus an
/// install-source-tailored action. Pure view over `ReleaseInfo` + `InstallSource`.
struct UpdateAvailableSheet: View {
    let info: ReleaseInfo
    let source: InstallSource
    let onDismiss: () -> Void
    let onRunUpdate: () -> Void
    @Environment(\.theme) var theme

    private let brewCommand = "brew upgrade --cask alas"

    private var subtitleText: String {
        switch info {
        case .stable(let s):
            return "Alas \(s.version.description) is available."
        case .nightly(let n):
            // Intentionally no timestamp: the release's `published_at` is
            // unreliable for the rolling nightly (updated in place), so the
            // tag's short SHA is the only trustworthy identifier the sheet
            // can show.
            return "Nightly \(n.shortSHA)"
        }
    }

    private var titleText: String {
        switch info {
        case .stable: return "Update available"
        case .nightly: return "New nightly available"
        }
    }

    private var viewReleaseLabel: String {
        switch info {
        case .stable: return "View Release Notes"
        case .nightly: return "View on GitHub"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                Text(subtitleText)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 6)

            ScrollView {
                Text(info.releaseNotes.isEmpty ? "No release notes provided." : info.releaseNotes)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-muted"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 220)
            .padding(.horizontal, 22).padding(.vertical, 12)

            actionRow
        }
        .frame(width: 480)
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var actionRow: some View {
        HStack(spacing: 8) {
            switch source {
            case .homebrew:
                Text(brewCommand)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .textSelection(.enabled)
                AlasButton(title: "Copy", style: .subtle) { Clipboard.copy(brewCommand) }
                Spacer()
                AlasButton(title: "View Release", style: .subtle) { NSWorkspace.shared.open(info.htmlURL) }
                AlasButton(title: "Update", style: .primary, action: onRunUpdate)
                AlasButton(title: "Later", style: .subtle, action: onDismiss)
            case .direct:
                AlasButton(title: viewReleaseLabel, style: .subtle) { NSWorkspace.shared.open(info.htmlURL) }
                Spacer()
                AlasButton(title: "Later", style: .subtle, action: onDismiss)
                AlasButton(title: "Download", style: .primary) {
                    NSWorkspace.shared.open(info.dmgURL ?? info.htmlURL)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(theme.color("bg-2"))
        .overlay(Divider().opacity(0.5), alignment: .top)
    }
}
