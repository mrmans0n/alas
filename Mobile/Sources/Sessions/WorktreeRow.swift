import AlasHighlight
import AlasRemoteKit
import SwiftUI

/// Display helpers ported from the web client's `repo-filter.js`. They stay in
/// the app, untested: the hash and palette mirror the web so a repo keeps its
/// color, and the rest is formatting.
enum RepoDisplay {
    private static let hues: [Double] = [200, 230, 260, 300, 330, 15, 45, 85, 130, 165]

    static func tileColor(_ name: String) -> Color {
        var hash: Int32 = 0
        for unit in name.utf16 { hash = hash &* 31 &+ Int32(unit) }
        let hue = hues[Int(abs(Int64(hash))) % hues.count]
        return oklch(l: 0.5, c: 0.13, hue: hue)
    }

    static func initials(_ name: String) -> String {
        let cleaned = name.hasPrefix(".") ? String(name.dropFirst()) : name
        let parts = cleaned.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        switch parts.count {
        case 0: return "?"
        case 1: return String(parts[0].prefix(2)).uppercased()
        default: return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
    }

    /// Line counts kept short enough to share a row: 1,284 reads as 1.3k.
    static func shortCount(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let k = (Double(n) / 100).rounded() / 10
        return k == k.rounded() ? "\(Int(k))k" : "\(k)k"
    }

    /// `updatedAt` is Unix seconds.
    static func relativeTime(_ updatedAt: Int64, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970.rounded()) - Int(updatedAt))
        if seconds < 60 { return "now" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return "\(hours) hr" }
        return "\(Int((Double(hours) / 24).rounded())) d"
    }

    private static func oklch(l: Double, c: Double, hue: Double) -> Color {
        let rgb = OKLCH(l: l, c: c, h: hue).linearSRGB()
        return Color(.sRGBLinear, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

struct RepoTile: View {
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Text(RepoDisplay.initials(name))
            .font(.system(size: size * 0.43, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RepoDisplay.tileColor(name), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One worktree, read like a row of the Mac sidebar: the branch with its
/// prefix faint, then what needs you (or what runs), the session it opens and
/// its line counts. With one session, a tap opens it; with several, each gets
/// its own row under the branch.
struct WorktreeRow: View {
    /// "Delegated by <parent>" for a delegated session, or "Delegated" when its parent is not listed.
    static func delegationCaption(_ session: RemoteSessionSummary, in host: RemoteSessionCatalog.Host?) -> String? {
        guard let parentId = session.parentSessionId else { return nil }
        let parent = host?.sections.lazy.flatMap(\.worktrees).flatMap { $0.activeSessions + $0.closedSessions }
            .first { $0.id == parentId }
        guard let title = parent?.title, !title.isEmpty else { return "Delegated" }
        return "Delegated by \(title)"
    }

    /// Session rows shown before "N more sessions" reveals the rest.
    private static let collapsedRowLimit = 3

    let entry: RemoteWorktreeEntry
    /// The machine holding it, named when its list mixes machines.
    var machine: String? = nil
    /// The session shown beside the list (iPad), when this worktree holds it.
    var selectedSessionId: String? = nil
    /// A session's caption, such as who delegated it.
    var caption: (RemoteSessionSummary) -> String? = { _ in nil }
    let open: (RemoteSessionSummary) -> Void

    @State private var expanded = false

    var body: some View {
        if entry.activeSessions.count < 2 {
            compactBody
        } else {
            sessionsBody
        }
    }

    private var compactBody: some View {
        let lead = entry.leadSession
        return Button { if let lead { open(lead) } } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 7)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        branchName
                        machineCapsule
                        Spacer(minLength: 6)
                        if let lead {
                            Text(RepoDisplay.relativeTime(lead.updatedAt))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    detailLine(lead)
                    if let caption = lead.flatMap(caption) {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(lead == nil)
        .listRowBackground(selectedSessionId != nil ? Color.accentColor.opacity(0.18) : nil)
        .accessibilityAddTraits(selectedSessionId != nil ? .isSelected : [])
    }

    /// Two or more sessions: the branch line is not a button, each session
    /// below it is, so a tap opens exactly the one you meant.
    private var sessionsBody: some View {
        let rows = entry.sessionRows
        let shown = expanded ? rows : Array(rows.prefix(Self.collapsedRowLimit))
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8).padding(.top, 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    branchName
                    machineCapsule
                    Spacer(minLength: 6)
                    if let s = entry.summary, s.conflictCount > 0 {
                        Text("\(s.conflictCount) conflict\(s.conflictCount == 1 ? "" : "s")")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.red)
                            .lineLimit(1).fixedSize()
                    }
                    lineCounts.font(.footnote.monospacedDigit())
                }
                ForEach(shown) { row in sessionRow(row) }
                if !expanded, rows.count > Self.collapsedRowLimit {
                    Button("\(rows.count - Self.collapsedRowLimit) more sessions") { expanded = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .padding(.leading, 22)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func sessionRow(_ row: RemoteSessionRow) -> some View {
        let session = row.session
        return Button { open(session) } label: {
            HStack(spacing: 6) {
                if row.depth == 1 {
                    Text("\u{21B3}").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                Circle().fill(sessionDotColor(session)).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                AgentLogo(agentId: session.agentId, size: 16).accessibilityHidden(true)
                Text(session.title).lineLimit(1)
                Spacer(minLength: 6)
                switch session.status {
                case "awaitingPermission": Text("Approval").fontWeight(.semibold).foregroundStyle(.orange)
                case "awaitingInput": Text("Input").fontWeight(.semibold).foregroundStyle(.orange)
                default: Text(RepoDisplay.relativeTime(session.updatedAt)).foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
            .padding(.leading, row.depth == 1 ? 16 : 0)
            .padding(.vertical, 3).padding(.horizontal, 4)
            .background(row.id == selectedSessionId ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(session.title), \(session.agentId)")
        .accessibilityHint(caption(session) ?? statusCaption(session))
        .accessibilityAddTraits(row.id == selectedSessionId ? .isSelected : [])
    }

    private func sessionDotColor(_ session: RemoteSessionSummary) -> Color {
        switch session.status {
        case "awaitingPermission", "awaitingInput": return .orange
        case "idle": return Color.secondary.opacity(0.35)
        default: return .blue
        }
    }

    private func statusCaption(_ session: RemoteSessionSummary) -> String {
        switch session.status {
        case "awaitingPermission": return "Needs approval"
        case "awaitingInput": return "Waiting for you"
        case "idle": return "Idle"
        default: return "Working"
        }
    }

    @ViewBuilder private var machineCapsule: some View {
        if let machine {
            Text(machine)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
                .layoutPriority(-1)
                .accessibilityLabel("on \(machine)")
        }
    }

    @ViewBuilder private var lineCounts: some View {
        if let s = entry.summary, s.addedLines + s.deletedLines > 0 {
            HStack(spacing: 4) {
                Text("+\(RepoDisplay.shortCount(s.addedLines))").foregroundStyle(.green)
                Text("\u{2212}\(RepoDisplay.shortCount(s.deletedLines))").foregroundStyle(.red)
            }
            .fixedSize()
        }
    }

    /// Folder projects and detached checkouts report no branch; name the
    /// worktree instead.
    private var branch: String {
        if let branch = entry.summary?.branch, !branch.isEmpty { return branch }
        return entry.title
    }

    /// The whole name when it fits, else the part after the last slash,
    /// which is where branches differ.
    private var branchName: some View {
        let name = branch
        let cut = name.lastIndex(of: "/").map { name.index(after: $0) } ?? name.startIndex
        let leaf = String(name[cut...])
        return ViewThatFits(in: .horizontal) {
            (Text(name[..<cut]).foregroundStyle(.secondary) + Text(leaf).fontWeight(.semibold))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Text(leaf).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityLabel(name)
    }

    private func detailLine(_ lead: RemoteSessionSummary?) -> some View {
        HStack(spacing: 6) {
            if let lead { AgentLogo(agentId: lead.agentId, size: 16).accessibilityHidden(true) }
            if let note = note(lead) {
                Text(note.text)
                    .fontWeight(note.leads ? .semibold : .regular)
                    .foregroundStyle(note.color)
                    .lineLimit(1).fixedSize()
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            Text(lead?.title ?? statusText)
                .foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            lineCounts
        }
        .font(.footnote.monospacedDigit())
    }

    private func note(_ lead: RemoteSessionSummary?) -> (text: String, color: Color, leads: Bool)? {
        if let s = entry.summary, s.conflictCount > 0 {
            return ("\(s.conflictCount) conflict\(s.conflictCount == 1 ? "" : "s")", .red, true)
        }
        switch lead?.status {
        case "awaitingPermission": return ("Needs approval", .orange, true)
        case "awaitingInput": return ("Waiting for you", .orange, true)
        case "idle", nil: return nil
        default: return ("Working", .blue, false)
        }
    }

    /// Shown when the worktree has no session to name.
    private var statusText: String {
        guard let s = entry.summary else { return "No sessions" }
        if !s.metricsAvailable { return "Changes unavailable" }
        return s.changedFileCount > 0 ? "\(s.changedFileCount) file\(s.changedFileCount == 1 ? "" : "s") changed" : "Clean"
    }

    private var dotColor: Color {
        if entry.needsAttention { return .orange }
        if entry.isRunning { return .blue }
        return Color.secondary.opacity(entry.isDirty ? 0.8 : 0.35)
    }
}
