import AlasRemoteKit
import SwiftUI

/// Count of queued prompts waiting to run; toggles the tray. Its own view so
/// queue churn re-renders the badge, not the composer.
struct QueueBadge: View {
    let session: TranscriptSession
    @Binding var open: Bool

    var body: some View {
        let count = RemoteQueueRules.waiting(session.queue).count
        if count > 0 {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                Label("\(count)", systemImage: "list.bullet")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(open ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(count) queued")
        }
    }
}

/// The waiting prompts, floating above the composer.
struct QueueTray: View {
    let session: TranscriptSession

    var body: some View {
        let waiting = RemoteQueueRules.waiting(session.queue)
        let targets = RemoteQueueRules.moveTargets(session.queue)
        let reorder = session.config?.supportsQueueReorder == true
        if !waiting.isEmpty { tray(waiting, targets, reorder) }
    }

    private func tray(_ waiting: [RemoteQueuedPrompt], _ targets: [String: RemoteQueueMoveTargets], _ reorder: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queued").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if RemoteQueueRules.canClear(session.queue) {
                    Button("Clear queue", role: .destructive) { session.queue(.clear) }
                        .font(.footnote.weight(.medium))
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(waiting, id: \.id) { item in
                        row(item, targets: targets[item.id], reorder: reorder)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func row(_ item: RemoteQueuedPrompt, targets: RemoteQueueMoveTargets?, reorder: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RemoteQueueRules.displayText(for: item)).font(.subheadline).lineLimit(3)
                if let at = item.scheduledAt {
                    Text("Scheduled for \(Date(timeIntervalSince1970: Double(at) / 1000).formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = item.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Send now", systemImage: "paperplane") { session.queue(.forceSend(item.id)) }
                if item.lastError != nil {
                    Button("Retry", systemImage: "arrow.clockwise") { session.queue(.retry(item.id)) }
                }
                if RemoteQueueRules.canEdit(item) {
                    Button("Edit", systemImage: "pencil") { session.queue(.edit(item.id)) }
                }
                if reorder, let targets {
                    if targets.up != nil {
                        Button("Move to top", systemImage: "arrow.up.to.line") { session.queue(.promote(item.id)) }
                    }
                    if let up = targets.up {
                        Button("Move up", systemImage: "arrow.up") { session.queue(.move(item.id, to: up)) }
                    }
                    if let down = targets.down {
                        Button("Move down", systemImage: "arrow.down") { session.queue(.move(item.id, to: down)) }
                    }
                }
                if item.canRemove != false {
                    Button("Remove", systemImage: "trash", role: .destructive) { session.queue(.remove(item.id)) }
                }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold))
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Queue item actions")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
