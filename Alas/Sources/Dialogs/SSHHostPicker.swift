import SwiftUI
import AppKit

/// Popover content: pick an SSH host from `~/.ssh/config`, or fall back to
/// free-text with guidance for hosts that aren't configured.
struct SSHHostPicker: View {
    @Binding var host: String
    let hosts: [SSHConfigHost]
    let isLoading: Bool
    @Binding var isPresented: Bool

    @Environment(\.theme) var theme
    @State private var search = ""

    private var filtered: [SSHConfigHost] {
        SSHHostSuggestions.filter(hosts, query: search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlasField(text: $search, placeholder: "Search hosts…", focusOnAppear: true)
                .padding(8)
            Divider().background(theme.color("line"))

            if isLoading {
                Text("Reading ~/.ssh/config…")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(12)
            } else if filtered.isEmpty {
                guidanceFooter
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { host in
                            row(host)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 320)
    }

    @ViewBuilder
    private func row(_ configHost: SSHConfigHost) -> some View {
        Button(action: {
            host = configHost.alias
            isPresented = false
        }) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .opacity(configHost.alias == host ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(configHost.alias)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = configHost.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.color("fg-faint"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var guidanceFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No match in ~/.ssh/config. Type any user@host directly, or add an entry:")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-dim"))
                .fixedSize(horizontal: false, vertical: true)
            let snippet = SSHHostSuggestions.snippet(for: search)
            HStack(alignment: .top, spacing: 8) {
                Text(snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                }) {
                    Text("Copy")
                        .font(.system(size: 10))
                        .foregroundColor(theme.color("fg-dim"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(theme.color("line"), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(theme.color("bg-0"))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
    }
}
