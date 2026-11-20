import AlasRemoteKit
import SwiftUI

/// A subagent's state as the wire names it: an `ACPSubagentState` raw value, read as the Mac's
/// `ACPSubagentRowPolicy` reads it. A value it does not know counts as still running.
/// ponytail: mirrors ACPSubagentState, which lives in AlasACP and the phone does not link; move
/// both into AlasRemoteKit if a third copy appears.
enum SubagentStatus {
    static func label(_ raw: String) -> String {
        switch raw {
        case "running", "created", "in_progress": "Working"
        case "requires_action": "Waiting for input"
        case "unconfirmed": "Not active"
        case "completed", "success": "Done"
        case "failed", "error": "Failed"
        case "cancelled", "canceled", "interrupted": "Cancelled"
        case "disconnected": "Disconnected"
        default: raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func isTerminal(_ raw: String) -> Bool {
        ["unconfirmed", "completed", "success", "failed", "error", "cancelled", "canceled", "interrupted",
         "disconnected"].contains(raw)
    }

    /// A child blocked on the user is live but not producing output.
    static func showsSpinner(_ raw: String) -> Bool {
        !isTerminal(raw) && raw != "requires_action"
    }

    static func isFailed(_ raw: String) -> Bool {
        raw == "failed" || raw == "error"
    }

    static func name(_ subagent: RemoteWireMessage.Subagent) -> String {
        subagent.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Subagent"
    }
}

/// The phone's `ACPSubagentRowView`: the child's name, state and task, and its error once it
/// failed. `open` is nil when the host cannot serve the child's transcript.
struct SubagentCard: View {
    let subagent: RemoteWireMessage.Subagent
    /// Set only once the child finished.
    let duration: String?
    let open: (() -> Void)?

    var body: some View {
        if let open {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the subagent's transcript")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "person.2").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(SubagentStatus.name(subagent)).font(.subheadline.weight(.medium)).lineLimit(1).layoutPriority(1)
                Text(SubagentStatus.label(subagent.state)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if let duration {
                    Text(duration).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if SubagentStatus.showsSpinner(subagent.state) {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                }
                if open != nil {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
            if let task = subagent.task, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(task.replacingOccurrences(of: "\n", with: " "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            // Often the only explanation a failed child leaves behind.
            if let error = subagent.lastError, SubagentStatus.isFailed(subagent.state) {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

/// A subagent's own transcript, read-only. Read once on appear, then every 2 s while the child
/// runs and this screen shows.
struct SubagentScreen: View {
    let session: TranscriptSession
    let subagent: RemoteWireMessage.Subagent
    @State private var expanded: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase

    private var transcript: SubagentTranscript? { session.subagentTranscripts[subagent.id] }

    /// The parent row's state as it last came.
    private var parentState: String? {
        session.items.lazy.compactMap(\.message.subagent).first { $0.id == subagent.id }?.state
    }

    /// The reply's state, else the parent row's.
    private var state: String {
        transcript?.state ?? parentState ?? subagent.state
    }

    /// The terminals of the child's expanded tool calls; the parent's terminal polling sees only its own rows.
    private var expandedTerminals: [String] {
        (transcript?.items ?? []).filter { expanded.contains($0.id) }.flatMap { item -> [String] in
            if case .toolCall(let call) = item.row { return call.terminalIds }
            return []
        }
    }

    private var isLive: Bool { transcript?.found != false && !SubagentStatus.isTerminal(state) }

    var body: some View {
        ScrollsUnderBars { insets in
            TranscriptCollectionView(items: transcript?.items ?? [], expanded: $expanded, canLoadOlder: false, loadOlder: {},
                                     session: session, interactive: false, insets: insets)
        }
            .overlay {
                if let transcript, !transcript.found {
                    Text("Subagent transcript not available.").font(.footnote).foregroundStyle(.secondary)
                } else if transcript == nil {
                    ProgressView()
                } else if transcript?.items.isEmpty == true {
                    Text("No messages yet").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(SubagentStatus.name(subagent))
            .navigationSubtitle(SubagentStatus.label(state))
            .navigationBarTitleDisplayMode(.inline)
            // Restarts when the child finishes, for one last read of its final rows, and stops in the
            // background. A read that could not go out (host offline) is retried until a reply lands.
            // The parent row's state restarts it too, so a child that resumes is read again.
            .task(id: [String(isLive), String(scenePhase == .active), parentState ?? ""]) {
                guard scenePhase == .active else { return }
                repeat {
                    session.readSubagent(subagent.id)
                    expandedTerminals.forEach(session.readTerminal)
                    guard isLive || transcript == nil else { return }
                    try? await Task.sleep(for: .seconds(2))
                } while !Task.isCancelled
            }
            .onChange(of: expanded) { old, new in
                guard new.count > old.count else { return }
                expandedTerminals.forEach(session.readTerminal)
            }
    }
}
