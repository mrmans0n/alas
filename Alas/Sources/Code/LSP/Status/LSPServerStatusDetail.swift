import AppKit
import SwiftUI

/// Popover section explaining why a server is loading or what killed it.
struct LSPServerStatusDetail: View {
    let phase: LSPServerStatus.Phase

    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        switch phase {
        case .indexing(let tasks):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tasks, id: \.token) { task in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title).font(scale.meta.font)
                        if let percentage = task.percentage {
                            ProgressView(value: Double(percentage), total: 100)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        if let message = task.message {
                            Text(message)
                                .font(scale.caption.font(weight: .regular, design: .monospaced))
                                .foregroundColor(theme.color("fg-muted"))
                                .lineLimit(2)
                        }
                    }
                }
            }
        case .crashed(let detail):
            VStack(alignment: .leading, spacing: 6) {
                Text(LSPCrashSummary.headline(detail)).font(scale.meta.font)
                if detail.termination != nil, let error = detail.initializeError {
                    Text("Failed to start: \(error)")
                        .font(scale.caption.font(weight: .regular))
                        .foregroundColor(theme.color("fg-muted"))
                }
                if !detail.outputTail.isEmpty {
                    ScrollView {
                        Text(detail.outputTail.joined(separator: "\n"))
                            .font(scale.caption.font(weight: .regular, design: .monospaced))
                            .foregroundColor(theme.color("fg-muted"))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(scale.space[2])
                    }
                    .frame(maxHeight: 120)
                    .background(theme.color("bg-1"))
                    .clipShape(RoundedRectangle(cornerRadius: scale.radius.small))
                    Button("Copy output") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(detail.outputTail.joined(separator: "\n"), forType: .string)
                    }
                }
            }
        case .starting, .ready:
            EmptyView()
        }
    }
}
