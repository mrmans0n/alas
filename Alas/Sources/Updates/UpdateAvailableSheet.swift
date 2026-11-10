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
    @Environment(\.designScale) private var scale

    private let brewCommand = SelfUpdateCommand.homebrew.displayCommandLine
    private var notesTypography: ACPChatTypography {
        ACPChatTypography(fontFamily: "", fontSize: Int(scale.meta.size))
    }

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
            VStack(alignment: .leading, spacing: scale.space[1]) {
                Text(titleText)
                    .font(.system(size: 15, weight: .semibold)) // design-literal: the one dialog title
                    .foregroundColor(theme.color("fg"))
                Text(subtitleText)
                    .font(scale.metaFont)
                    .foregroundColor(theme.color("fg-dim"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, scale.space[5]).padding(.top, scale.space[4]).padding(.bottom, scale.space[2])

            ScrollView {
                Group {
                    if info.releaseNotes.isEmpty {
                        Text("No release notes provided.")
                            .font(scale.metaFont)
                            .foregroundColor(theme.color("fg-muted"))
                    } else {
                        ACPMarkdownText(
                            raw: info.releaseNotes,
                            typography: notesTypography,
                            showsCodeBlockCopyButton: false,
                            // Release notes keep the spacing they had before the transcript's scale.
                            spacing: .init(block: 8, line: 0)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220) // design-literal: fixed release-notes viewport
            .padding(.horizontal, scale.space[5]).padding(.vertical, scale.space[3])

            actionRow
        }
        .frame(width: 480) // design-literal: fixed sheet width
        .background(theme.color("bg-1"))
        .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
    }

    @ViewBuilder private var actionRow: some View {
        switch source {
        case .homebrew:
            VStack(alignment: .leading, spacing: scale.space[2]) {
                HStack(alignment: .firstTextBaseline, spacing: scale.space[2]) {
                    Text(brewCommand)
                        .font(scale.meta.font(design: .monospaced))
                        .foregroundColor(theme.color("fg"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    AlasButton(title: "Copy", style: .subtle) { Clipboard.copy(brewCommand) }
                        .fixedSize()
                    Spacer(minLength: 0)
                }
                HStack(spacing: scale.space[2]) {
                    AlasButton(title: viewReleaseLabel, style: .subtle) { NSWorkspace.shared.open(info.htmlURL) }
                        .fixedSize()
                    Spacer()
                    AlasButton(title: "Later", style: .subtle, action: onDismiss)
                        .fixedSize()
                    AlasButton(title: "Update", style: .primary, action: onRunUpdate)
                        .fixedSize()
                }
            }
            .actionRowChrome(theme: theme, horizontal: scale.space[4], vertical: scale.space[3])
        case .direct:
            HStack(spacing: scale.space[2]) {
                AlasButton(title: viewReleaseLabel, style: .subtle) { NSWorkspace.shared.open(info.htmlURL) }
                    .fixedSize()
                Spacer()
                AlasButton(title: "Later", style: .subtle, action: onDismiss)
                    .fixedSize()
                AlasButton(title: "Download", style: .primary) {
                    NSWorkspace.shared.open(info.dmgURL ?? info.htmlURL)
                }
                .fixedSize()
            }
            .actionRowChrome(theme: theme, horizontal: scale.space[4], vertical: scale.space[3])
        }
    }
}

private extension View {
    func actionRowChrome(theme: Theme, horizontal: CGFloat, vertical: CGFloat) -> some View {
        padding(.horizontal, horizontal).padding(.vertical, vertical)
            .background(theme.color("bg-2"))
            .overlay(Divider().opacity(0.5), alignment: .top)
    }
}
