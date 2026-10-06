import SwiftUI

/// Up to `inlineLimit` chips inline; beyond that, one summary pill whose
/// popover lists every server.
struct LSPServerChipStrip: View {
    let chips: [LSPServerChipModel]
    let appState: AppState

    @State private var popoverOpen = false

    var body: some View {
        switch LSPServerChipAggregation.presentation(chips.map(\.snapshot)) {
        case .inline:
            HStack(spacing: 2) {
                ForEach(chips) { chip in
                    LSPServerChip(model: chip, appState: appState)
                }
            }
        case .summary(let ready, let total, let worst):
            Button { popoverOpen.toggle() } label: {
                LSPStatusPill(
                    glyph: Self.glyph(for: worst),
                    label: "LSP \(ready)/\(total)",
                    showsWarning: worst == .problem,
                    isHighlighted: popoverOpen
                )
            }
            .buttonStyle(.plain)
            .help("\(ready) of \(total) language servers ready")
            .accessibilityLabel(Text("Language servers: \(ready) of \(total) ready"))
            .accessibilityHint(Text("Lists every language server for this review"))
            .accessibilityAddTraits(.isButton)
            .popover(isPresented: $popoverOpen, arrowEdge: .top) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(chips) { chip in
                            DisclosureGroup {
                                LSPServerChipPopoverBody(model: chip, appState: appState) { popoverOpen = false }
                                    .padding(.leading, 4)
                            } label: {
                                LSPStatusPill(state: chip.badgeState)
                            }
                        }
                    }
                    .padding(10)
                }
                .frame(width: 320)
                .frame(maxHeight: 420)
            }
        }
    }

    private static func glyph(for severity: LSPChipSeverity) -> LSPPillGlyph {
        switch severity {
        case .ready: .ready
        case .loading: .loading
        case .problem: .problem
        }
    }
}
