import AlasCore
import Foundation

/// What a worktree row shows, decided apart from how it draws it.
///
/// A row is two lines: the name, then everything the row knows, always on
/// screen so a scan of the list reads it without a pointer.
enum WorktreeRowPresentation {
    struct MachineBadge: Equatable {
        let label: String
        let state: RemoteHostReachability
    }

    /// The machine a linked record's row runs on, shown in its primary's
    /// group. Nil for the group's own rows.
    nonisolated static func machineBadge(
        rowProjectId: String,
        groupProjectId: String,
        host: String?,
        machines: [Machine],
        reachability: RemoteHostReachability
    ) -> MachineBadge? {
        guard rowProjectId != groupProjectId, let host else { return nil }
        let label = machines.first { $0.destination == host }?.label ?? host
        return MachineBadge(label: label, state: reachability)
    }

    /// Agent state and conflicts get a coloured dot and lead line 2. A plain
    /// file count gets neither.
    nonisolated static func isStatusLoud(
        harnessState: HarnessService.AggregatedState?,
        worktreeStatus: WorktreeDirtyState
    ) -> Bool {
        if harnessState != nil { return true }
        if case .dirty(_, let conflictCount) = worktreeStatus { return conflictCount > 0 }
        return false
    }

    /// A branch name split at its last slash: "nacho/fix-x" reads as a dim
    /// "nacho/" and the part that tells siblings apart. Names without a
    /// slash, or ending in one, have no prefix.
    nonisolated static func nameParts(_ title: String) -> (prefix: String, leaf: String) {
        guard let slash = title.lastIndex(of: "/"), title.index(after: slash) < title.endIndex else {
            return ("", title)
        }
        let cut = title.index(after: slash)
        return (String(title[..<cut]), String(title[cut...]))
    }

    /// Short enough to sit beside a name: "5m", "3h", "2d".
    nonisolated static func compactAge(since date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        case ..<2_592_000: return "\(seconds / 604_800)w"
        case ..<31_536_000: return "\(seconds / 2_592_000)mo"
        default: return "\(seconds / 31_536_000)y"
        }
    }

    /// A line count short enough for a row: "840", "1.3k", "22k", "1.2M".
    /// Written out rather than localized, so every row groups digits alike.
    nonisolated static func compactCount(_ count: Int) -> String {
        func scaled(_ unit: Int, _ suffix: String) -> String {
            let tenths = count / (unit / 10)
            if tenths >= 100 { return "\(count / unit)\(suffix)" }
            return tenths % 10 == 0 ? "\(tenths / 10)\(suffix)" : "\(tenths / 10).\(tenths % 10)\(suffix)"
        }
        switch count {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return scaled(1_000, "k")
        default: return scaled(1_000_000, "M")
        }
    }

    /// Being behind upstream has a pull action waiting; being ahead does not.
    nonisolated static func upstreamItemsAtRest(
        _ items: [WorktreeUpstreamStatus.SubtitleItem]
    ) -> [WorktreeUpstreamStatus.SubtitleItem] {
        items.filter { $0.text.hasPrefix("↓") }
    }

    /// Spoken for the whole row, so its parts read as one sentence.
    nonisolated static func accessibilityLabel(_ content: WorktreeRowAccessibilityContent) -> String {
        var parts = [content.name]
        if let ship = content.ship { parts.append(ship) }
        if let statusNote = content.statusNote { parts.append(statusNote) }
        if let shepherd = content.shepherd { parts.append(shepherd) }
        if content.added > 0 || content.deleted > 0 {
            parts.append("\(content.added) lines added, \(content.deleted) lines deleted")
        }
        if let workspaceCheckout = content.workspaceCheckout { parts.append(workspaceCheckout) }
        if let commits = content.commits { parts.append(commits) }
        parts += content.upstream
        if let stack = content.stack { parts.append(stack) }
        parts += content.agents
        if let explanation = content.explanation { parts.append(explanation) }
        parts.append(content.lastActivity)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Live activity

/// What a worktree is running right now: VMs and devices it owns, a stack
/// ship in flight, a shepherd watching its pull requests. Decided here, drawn
/// by the row.
extension WorktreeRowPresentation {
    enum ResourceKind: Equatable {
        /// The strongest guest, when several VMs collapse into one glyph.
        case vm(VMGuestOS)
        case iosSimulator
        case androidEmulator
    }

    enum ResourceState: Equatable {
        case starting, on, paused
    }

    struct ResourceGlyph: Equatable {
        let kind: ResourceKind
        let state: ResourceState
        let count: Int
        let tooltip: String
        /// The device a click shows; nil for VMs.
        let deviceID: String?
    }

    struct OwnedDevice: Equatable {
        let id: String
        let name: String
        let isAndroid: Bool
        /// Nil when the device is shut down.
        let state: ResourceState?
    }

    /// At most one glyph per kind, in the order VM, iOS simulator, Android
    /// emulator, so a busy worktree keeps its name line.
    nonisolated static func resourceGlyphs(
        vms: [VMGuestOS: VMDeviceStatus],
        devices: [OwnedDevice]
    ) -> [ResourceGlyph] {
        var glyphs: [ResourceGlyph] = []

        var liveVMs: [(guest: VMGuestOS, state: ResourceState, word: String)] = []
        for guest in [VMGuestOS.macOS, .linux] {
            guard let status = vms[guest] else { continue }
            switch status {
            case .starting: liveVMs.append((guest, .starting, "starting"))
            case .pausing: liveVMs.append((guest, .starting, "pausing"))
            case .running: liveVMs.append((guest, .on, "running"))
            case .paused: liveVMs.append((guest, .paused, "paused"))
            case .notCreated, .stopped, .runningElsewhere: break
            }
        }
        if let strongest = liveVMs.max(by: { rank($0.state) < rank($1.state) }) {
            let tooltip = liveVMs.map { "\($0.guest == .macOS ? "macOS" : "Linux") VM \($0.word)" }.joined(separator: ", ")
            glyphs.append(ResourceGlyph(
                kind: .vm(strongest.guest), state: strongest.state, count: liveVMs.count,
                tooltip: tooltip, deviceID: nil
            ))
        }

        for android in [false, true] {
            let live = devices.filter { $0.isAndroid == android && $0.state != nil }
            guard let first = live.first else { continue }
            let state: ResourceState = live.contains { $0.state == .starting } ? .starting : .on
            let tooltip = live.map { device in
                let name = android ? "\(device.name) (emulator)" : device.name
                return "\(name) \(device.state == .starting ? "booting" : "booted")"
            }.joined(separator: ", ")
            glyphs.append(ResourceGlyph(
                kind: android ? .androidEmulator : .iosSimulator, state: state,
                count: live.count, tooltip: tooltip, deviceID: first.id
            ))
        }
        return glyphs
    }

    /// Starting beats running beats paused; the first of equals wins.
    private nonisolated static func rank(_ state: ResourceState) -> Int {
        switch state {
        case .starting: 2
        case .on: 1
        case .paused: 0
        }
    }

    // MARK: Ship

    struct ShipLine: Equatable {
        let title: String
        /// The entry in flight, only while linting or pushing with a known total.
        let position: Int?
        let total: Int?
        let isFailure: Bool
        let tooltip: String
        let sessionID: String
    }

    nonisolated static func shipLine(_ activity: StackShipActivity?) -> ShipLine? {
        switch activity {
        case nil:
            return nil
        case .running(let sessionID, let progress)?:
            let title = "Shipping stack · \(progress.phase.rawValue)"
            let hasBar = (progress.phase == .linting || progress.phase == .pushing) && progress.totalEntries != nil
            let position = hasBar ? progress.position : nil
            let total = hasBar ? progress.totalEntries : nil
            let tooltip = if let position, let total { "\(title) \(position)/\(total)" } else { title }
            return ShipLine(
                title: title, position: position, total: total,
                isFailure: false, tooltip: tooltip, sessionID: sessionID
            )
        case .failed(let sessionID, let message)?:
            let end = message.firstIndex(where: \.isNewline) ?? message.endIndex
            let firstLine = message[..<end].trimmingCharacters(in: .whitespaces)
            let short = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
            return ShipLine(
                title: short.isEmpty ? "Ship failed" : "Ship failed: \(short)", position: nil, total: nil,
                isFailure: true, tooltip: message, sessionID: sessionID
            )
        }
    }

    // MARK: Shepherd

    struct ShepherdNote: Equatable {
        /// "#2041", or "4 PRs" for a stack.
        let number: String
        let note: String?
        /// Needs the user: leads line 2 like conflicts do.
        let isLoud: Bool
        let tooltip: String
        let sessionID: String
        /// A stack shepherd stands in for the gg stack chip.
        let replacesStackChip: Bool
    }

    /// A stack shepherd wins over a single PR's. Finished and idle shepherds
    /// say nothing.
    nonisolated static func shepherdNote(pr: ShepherdRecord?, stack: StackShepherdRecord?) -> ShepherdNote? {
        if let stack, !stack.isFinished {
            let presentation = ShepherdPresentation.make(stack: stack, requests: [:], gatePasses: false)
            let merged = stack.entries.filter { $0.shepherd.phase == .merged }.count
            guard let (note, isLoud) = shepherdWording(presentation.badge, loud: "need you") else { return nil }
            let count = stack.entries.count
            let label = stack.remote.kind == .gitlab ? "MR" : "PR"
            let number = "\(count) \(label)\(count == 1 ? "" : "s")"
            let resolved = note ?? (merged > 0 ? "\(merged) merged" : nil)
            return ShepherdNote(
                number: number, note: resolved, isLoud: isLoud,
                tooltip: presentation.tooltip, sessionID: stack.sessionID, replacesStackChip: true
            )
        }
        guard let pr else { return nil }
        let presentation = ShepherdPresentation.make(record: pr, request: nil, mergeGatePasses: false)
        guard let (note, isLoud) = shepherdWording(presentation.badge, loud: "needs you") else { return nil }
        return ShepherdNote(
            number: presentation.number ?? "", note: note, isLoud: isLoud,
            tooltip: presentation.tooltip, sessionID: pr.sessionID, replacesStackChip: false
        )
    }

    /// Nil hides the shepherd; a nil note shows the number alone.
    private nonisolated static func shepherdWording(
        _ badge: ShepherdBadgeState,
        loud: String
    ) -> (note: String?, isLoud: Bool)? {
        switch badge {
        case .waiting: (nil, false)
        case .fixing: ("agent fixing", false)
        case .ready: ("ready to merge", false)
        case .merging: ("merging", false)
        case .queued: ("in merge queue", false)
        case .attention: (loud, true)
        case .merged, .closed, .noRequest, .unshepherded: nil
        }
    }

    // MARK: Bundle

    struct LiveActivity: Equatable {
        var glyphs: [ResourceGlyph]
        var ship: ShipLine?
        var shepherd: ShepherdNote?

        nonisolated static let none = LiveActivity(glyphs: [], ship: nil, shepherd: nil)
    }

    /// A row a linked record on another machine contributes shows nothing
    /// local: its VMs, devices and ships run elsewhere.
    nonisolated static func liveActivity(
        hasMachineBadge: Bool,
        vms: [VMGuestOS: VMDeviceStatus],
        devices: [OwnedDevice],
        ship: StackShipActivity?,
        pr: ShepherdRecord?,
        stack: StackShepherdRecord?
    ) -> LiveActivity {
        guard !hasMachineBadge else { return .none }
        return LiveActivity(
            glyphs: resourceGlyphs(vms: vms, devices: devices),
            ship: shipLine(ship),
            shepherd: shepherdNote(pr: pr, stack: stack)
        )
    }
}

/// Everything a row can say, for its accessibility label. No defaults: a new
/// row fact has to be supplied here, and the test reads every field by
/// reflection, so one the label forgets fails.
struct WorktreeRowAccessibilityContent {
    let name: String
    /// The stack ship that takes over line 2.
    let ship: String?
    let statusNote: String?
    let shepherd: String?
    let added: Int
    let deleted: Int
    let workspaceCheckout: String?
    let commits: String?
    let upstream: [String]
    let stack: String?
    let agents: [String]
    let explanation: String?
    let lastActivity: String
}
