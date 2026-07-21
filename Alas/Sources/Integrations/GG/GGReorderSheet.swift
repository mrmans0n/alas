import SwiftUI

enum GGReorderMoveResult: Equatable {
    case moved
    case immutableBoundary
}

enum GGReorderSheetAction: Equatable {
    case apply
    case cancel
}

struct GGReorderEntry: Equatable, Identifiable {
    let id: String
    let title: String
    let isMutable: Bool

    static func mutable(id: String, title: String) -> GGReorderEntry {
        GGReorderEntry(id: id, title: title, isMutable: true)
    }

    static func immutable(id: String, title: String) -> GGReorderEntry {
        GGReorderEntry(id: id, title: title, isMutable: false)
    }
}

struct GGReorderModel: Equatable {
    private(set) var entries: [GGReorderEntry]
    private let originalIDs: [String]

    init(entries: [GGReorderEntry]) {
        self.entries = entries
        originalIDs = entries.map(\.id)
    }

    var orderedIDs: [String] { entries.map(\.id) }
    var hasChanges: Bool { orderedIDs != originalIDs }
    var availableActions: [GGReorderSheetAction] { [.apply, .cancel] }

    mutating func move(from source: Int, to destination: Int) -> GGReorderMoveResult {
        guard entries.indices.contains(source),
              entries.startIndex...entries.endIndex ~= destination,
              entries[source].isMutable
        else { return .immutableBoundary }
        let region = mutableRegion(containing: source)
        let target = destination == region.upperBound + 1 ? region.upperBound : destination
        guard region.contains(target) else { return .immutableBoundary }
        guard source != destination else { return .moved }
        let entry = entries.remove(at: source)
        entries.insert(entry, at: target)
        return .moved
    }

    private func mutableRegion(containing index: Int) -> ClosedRange<Int> {
        var lower = index
        var upper = index
        while lower > entries.startIndex, entries[lower - 1].isMutable { lower -= 1 }
        while upper + 1 < entries.endIndex, entries[upper + 1].isMutable { upper += 1 }
        return lower...upper
    }
}

struct GGReorderPresentation: Equatable, Identifiable {
    let snapshot: GGStackIdentity
    var model: GGReorderModel

    var id: String { "\(snapshot.stackName):\(snapshot.headSHA)" }
}

struct GGReorderSheet: View {
    let presentation: GGReorderPresentation
    let onApply: (GGReorderModel) async throws -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var model: GGReorderModel
    @State private var isApplying = false
    @State private var errorMessage: String?

    init(
        presentation: GGReorderPresentation,
        onApply: @escaping (GGReorderModel) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.onApply = onApply
        self.onCancel = onCancel
        _model = State(initialValue: presentation.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Reorder Stack")
                .font(.system(size: 16, weight: .semibold))
            Text("Drag commits within each mutable section.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.color("fg-dim"))

            List {
                ForEach(model.entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.isMutable ? "line.3.horizontal" : "lock.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.color("fg-faint"))
                            .frame(width: 16, height: 16)
                        Text(entry.title)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(entry.id)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                    }
                    .frame(height: 30)
                    .moveDisabled(!entry.isMutable)
                }
                .onMove { offsets, destination in
                    guard let source = offsets.first else { return }
                    let target = min(
                        max(0, destination > source ? destination - 1 : destination),
                        model.entries.count - 1
                    )
                    _ = model.move(from: source, to: target)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minWidth: 500, minHeight: 260)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("warn"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges || isApplying)
            }
        }
        .padding(18)
        .interactiveDismissDisabled(isApplying)
    }

    private func apply() {
        guard model.hasChanges, !isApplying else { return }
        isApplying = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await onApply(model)
                dismiss()
            } catch {
                errorMessage = GGErrorPresentation.message(for: error)
                isApplying = false
            }
        }
    }
}
