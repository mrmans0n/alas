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

    static func status(_ entry: RemoteWorktreeEntry) -> (label: String, isDirty: Bool) {
        if entry.isRunning { return ("running", false) }
        guard let s = entry.summary else { return ("clean", false) }
        if !s.metricsAvailable { return ("changes unavailable", false) }
        if s.conflictCount > 0 { return ("\(s.conflictCount) conflict\(s.conflictCount == 1 ? "" : "s")", true) }
        if s.changedFileCount > 0 { return ("\(s.changedFileCount) file\(s.changedFileCount == 1 ? "" : "s")", true) }
        return ("clean", false)
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
        let h = hue * .pi / 180
        let a = c * cos(h), b = c * sin(h)
        let l_ = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m_ = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s_ = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func gamma(_ v: Double) -> Double {
            let x = min(max(v, 0), 1)
            return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        return Color(red: gamma(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_),
                     green: gamma(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_),
                     blue: gamma(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_))
    }
}

struct RepoTile: View {
    let name: String

    var body: some View {
        Text(RepoDisplay.initials(name))
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(RepoDisplay.tileColor(name), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One worktree: branch, status line, diff stats, and its open sessions as
/// tappable sub-rows. `open` reports the tapped session.
struct WorktreeRow: View {
    let entry: RemoteWorktreeEntry
    let open: (RemoteSessionSummary) -> Void

    var body: some View {
        let status = RepoDisplay.status(entry)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.summary?.branch ?? entry.title)
                    .font(.headline)
                    .lineLimit(1)
                if entry.needsAttention {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                        .accessibilityLabel("Needs attention")
                }
                Spacer(minLength: 8)
                if let s = entry.summary, s.addedLines + s.deletedLines > 0 {
                    HStack(spacing: 6) {
                        Text("+\(s.addedLines)").foregroundStyle(.green)
                        Text("\u{2212}\(s.deletedLines)").foregroundStyle(.red)
                    }
                    .font(.caption.monospacedDigit().weight(.medium))
                }
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.isRunning ? Color.blue : status.isDirty ? Color.orange : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(status.label)
                    .font(.subheadline)
                    .foregroundStyle(entry.isRunning ? Color.blue : .secondary)
            }
            .padding(.leading, 22)
            ForEach(entry.activeSessions, id: \.id) { session in
                Button { open(session) } label: { SessionLine(session: session) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SessionLine: View {
    let session: RemoteSessionSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.fill")
                .font(.caption)
                .foregroundStyle(tint)
            Text(session.title)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(RepoDisplay.relativeTime(session.updatedAt))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.leading, 22)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch session.status {
        case "idle": .secondary
        case "awaitingPermission", "awaitingInput": .orange
        default: .blue
        }
    }
}
