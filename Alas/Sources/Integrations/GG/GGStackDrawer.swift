import SwiftUI

struct GGStackDrawer: View {
    @Bindable var rps: RightPaneState
    let appState: AppState

    @Environment(\.theme) private var theme
    @State private var expanded = false

    private var model: GGStackReadinessModel? {
        rps.ggStack.map { GGStackReadinessModel.make(stack: $0, action: rps.ggActionState) }
    }

    var body: some View {
        if let model {
            VStack(spacing: 0) {
                Rectangle().fill(theme.color("accent").opacity(0.24)).frame(height: 1)
                collapsedRow(model)
                if expanded { expandedBody(model) }
            }
            .background(theme.color("bg-1").opacity(0.97))
        }
    }

    private func collapsedRow(_ model: GGStackReadinessModel) -> some View {
        HStack(spacing: 7) {
            Circle().fill(theme.color(model.isPaused ? "warn" : "accent")).frame(width: 6, height: 6)
            Icon(name: "branch", size: 11, color: theme.color("fg-faint"))
            Text(model.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                .foregroundColor(theme.color("fg-muted")).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            Text(model.summaryChip)
                .font(.system(size: 10.5, weight: .medium)).foregroundColor(theme.color("fg-dim"))
            Icon(name: expanded ? "chev-down" : "chev-right", size: 10, color: theme.color("fg-faint"))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }

    @ViewBuilder
    private func expandedBody(_ model: GGStackReadinessModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.progressRows.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(model.progressRows.enumerated()), id: \.offset) { _, row in
                        Text(row).font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
                    }
                }
            } else {
                if model.isPaused {
                    Text("A gg operation is paused on conflicts. Resolve them in the Conflicts section, then Continue — or Abort to roll back.")
                        .font(.system(size: 11)).foregroundColor(theme.color("fg-dim"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = rps.ggActionState.lastError {
                    Text(err).font(.system(size: 11)).foregroundColor(theme.color("warn")).lineLimit(3)
                }
                actionRow(model)
                factsView(model)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private func actionRow(_ model: GGStackReadinessModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.actions) { action in
                    Button {
                        if action.kind == .land { rps.requestGGLand(.ready) }
                        else { rps.onGGStackAction(action.kind, appState: appState) }
                    } label: {
                        HStack(spacing: 6) {
                            if action.isInFlight { Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 10, height: 10) }
                            Text(action.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundColor(action.emphasis == .primary ? theme.color("bg-0") : theme.color("fg-muted"))
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(action.emphasis == .primary ? theme.color("accent") : theme.color("bg-3").opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(!action.isEnabled)
                    .opacity(action.isEnabled || action.isInFlight ? 1 : 0.5)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func factsView(_ model: GGStackReadinessModel) -> some View {
        VStack(spacing: 4) {
            ForEach(model.facts) { fact in
                HStack(spacing: 8) {
                    Text(fact.label).font(.system(size: 10.5)).foregroundColor(theme.color("fg-faint"))
                    Spacer(minLength: 8)
                    Text(fact.value).font(.system(size: 10.5, weight: .semibold)).foregroundColor(theme.color("fg-dim"))
                }
                .padding(.horizontal, 7).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(theme.color("bg-2").opacity(0.48)))
            }
        }
    }
}
