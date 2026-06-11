import SwiftUI
import AppKit

/// Popover-based picker that shows a font list with per-row preview.
/// The trigger renders the currently-selected family in that family.
struct FontFamilyPicker: View {
    @Binding var family: String
    let catalog: [String]
    let defaultLabel: String?
    let emptyCatalogMessage: String

    @Environment(\.theme) var theme
    @State private var open = false
    @State private var search = ""

    init(
        family: Binding<String>,
        catalog: [String],
        defaultLabel: String? = nil,
        emptyCatalogMessage: String = "No monospace fonts found"
    ) {
        self._family = family
        self.catalog = catalog
        self.defaultLabel = defaultLabel
        self.emptyCatalogMessage = emptyCatalogMessage
    }

    var body: some View {
        Button(action: { open.toggle() }) {
            HStack(spacing: 6) {
                Text(triggerLabel)
                    .font(triggerFont)
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.color("fg-dim"))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(theme.color("bg-0"))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.color("line"), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .settingsDropdownFrame()
        .popover(isPresented: $open, arrowEdge: .bottom) {
            popoverBody
        }
    }

    private var isInstalled: Bool { catalog.contains(family) }

    private var triggerLabel: String {
        if family.isEmpty, let defaultLabel {
            return defaultLabel
        }
        return isInstalled || family.isEmpty ? family : "\(family) (not installed)"
    }

    private var triggerFont: Font {
        if isInstalled, !family.isEmpty {
            return Font.custom(family, size: 12)
        }
        return .system(size: 12)
    }

    private var filteredCatalog: [String] {
        if search.isEmpty { return catalog }
        return catalog.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder
    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlasField(text: $search, placeholder: "Search fonts…")
                .padding(8)

            Divider().background(theme.color("line"))

            if catalog.isEmpty, defaultLabel == nil {
                Text(emptyCatalogMessage)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg-dim"))
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let defaultLabel {
                            row(name: "", displayName: defaultLabel, missing: false)
                            Divider().background(theme.color("line"))
                        }
                        if !isInstalled, !family.isEmpty {
                            row(name: family, missing: true)
                            Divider().background(theme.color("line"))
                        }
                        if catalog.isEmpty {
                            Text(emptyCatalogMessage)
                                .font(.system(size: 12))
                                .foregroundColor(theme.color("fg-dim"))
                                .padding(12)
                        }
                        ForEach(filteredCatalog, id: \.self) { name in
                            row(name: name, missing: false)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 280)
    }

    @ViewBuilder
    private func row(name: String, displayName: String? = nil, missing: Bool) -> some View {
        Button(action: {
            family = name
            open = false
        }) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg"))
                    .opacity(name == family ? 1 : 0)
                Text(missing ? "\(name) (not installed)" : (displayName ?? name))
                    .font(name.isEmpty || missing ? .system(size: 13) : .custom(name, size: 14))
                    .foregroundColor(missing ? theme.color("fg-dim") : theme.color("fg"))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(missing)
    }
}
