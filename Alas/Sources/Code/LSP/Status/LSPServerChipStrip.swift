import SwiftUI

/// Up to `inlineLimit` chips inline; beyond that, one summary pill whose
/// popover lists every server.
struct LSPServerChipStrip: View {
    let chips: [LSPServerChipModel]
    let appState: AppState

    @State private var popoverOpen = false

    var body: some View {
        // Snapshots read every server's live phase; only the summary needs them,
        // so inline chips observe just their own status.
        if LSPServerChipAggregation.isInline(count: chips.count) {
            HStack(spacing: 2) {
                ForEach(chips) { chip in
                    LSPServerChip(model: chip, appState: appState)
                }
            }
        } else if case .summary(let ready, let total, let worst) = LSPServerChipAggregation.presentation(chips.map(\.snapshot)) {
            summary(ready: ready, total: total, worst: worst)
        }
    }

    private func summary(ready: Int, total: Int, worst: LSPChipSeverity) -> some View {
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
        .accessibilityLabel(Text("Language servers: \(ready) of \(total) ready, \(Self.worstText(worst))"))
        .accessibilityHint(Text("Lists every language server for this review"))
        .accessibilityAddTraits(.isButton)
        .popover(isPresented: $popoverOpen, arrowEdge: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(chips) { chip in
                        let state = chip.badgeState
                        DisclosureGroup {
                            LSPServerChipPopoverBody(model: chip, appState: appState) { popoverOpen = false }
                                .padding(.leading, 4)
                        } label: {
                            LSPStatusPill(state: state)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text("\(state.label), \(state.tooltip)"))
                        }
                    }
                }
                .padding(10)
            }
            .frame(width: 320)
            .frame(maxHeight: 420)
        }
    }

    private static func worstText(_ severity: LSPChipSeverity) -> String {
        switch severity {
        case .ready: "all ready"
        case .loading: "some loading"
        case .problem: "some with problems"
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
