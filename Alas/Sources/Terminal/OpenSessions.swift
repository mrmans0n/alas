// OpenSessions.swift
// View-model types + the pure classifier behind the Settings › Terminal
// "Open sessions" section. Splits `zmx ls` output into the sessions this
// window owns ("active") and everything else ("orphaned"), and judges each
// orphan idle vs in-use by its attached-client count.

import Foundation

/// A live registry entry projected into a value type, so the pure classifier
/// never has to touch the `@MainActor` `TerminalSession`/`SessionRegistry`.
struct TrackedSessionRef: Equatable, Sendable {
    let leafId: String
    let worktreeId: String
    /// Bare (unprefixed) zmx session name, or nil when the pane isn't
    /// zmx-backed (keep-alive off or zmx unavailable).
    let zmxSessionName: String?
}

/// One open zmx session as rendered in the settings list.
struct OpenSessionRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case active(leafId: String, worktreeId: String)  // tracked by this window
        case orphanIdle                                   // clients == 0
        case orphanInUse                                  // clients >= 1 or unknown
    }

    let name: String        // bare zmx session name; unique per session
    let kind: Kind
    let startDir: String?
    let cmd: String?
    let clients: Int?
    let created: Int?       // unix epoch seconds

    var id: String { name }

    var isOrphan: Bool {
        switch kind {
        case .active: return false
        case .orphanIdle, .orphanInUse: return true
        }
    }

    var isIdle: Bool {
        if case .orphanIdle = kind { return true }
        return false
    }
}

/// The two-bucket result the settings view renders.
struct OpenSessionsSnapshot: Equatable, Sendable {
    var active: [OpenSessionRow]
    var orphaned: [OpenSessionRow]

    static let empty = OpenSessionsSnapshot(active: [], orphaned: [])

    var isEmpty: Bool { active.isEmpty && orphaned.isEmpty }
}

/// Pure split of `zmx ls` output into active (this-window) vs orphaned
/// sessions. No subprocess, no actor isolation — directly unit-testable.
enum OpenSessionsClassifier {
    static func classify(
        infos: [ZmxSessionInfo],
        tracked: [TrackedSessionRef],
        sessionPrefix: String
    ) -> OpenSessionsSnapshot {
        // Bare-name -> info, so active lookups and orphan filtering both work
        // off the prefix-stripped name the registry uses.
        var infoByBareName: [String: ZmxSessionInfo] = [:]
        for info in infos where info.name.hasPrefix(sessionPrefix) {
            let bare = String(info.name.dropFirst(sessionPrefix.count))
            infoByBareName[bare] = info
        }

        let trackedWithName = tracked.compactMap { ref -> (String, TrackedSessionRef)? in
            ref.zmxSessionName.map { ($0, ref) }
        }
        let trackedNames = Set(trackedWithName.map(\.0))

        let active: [OpenSessionRow] = trackedWithName.map { bareName, ref in
            let info = infoByBareName[bareName]
            return OpenSessionRow(
                name: bareName,
                kind: .active(leafId: ref.leafId, worktreeId: ref.worktreeId),
                startDir: info?.startDir,
                cmd: info?.cmd,
                clients: info?.clients,
                created: info?.created
            )
        }
        .sorted { $0.name < $1.name }

        var orphaned: [OpenSessionRow] = []
        for (bareName, info) in infoByBareName {
            guard bareName.hasPrefix("alas-") else { continue }  // ours only
            guard !trackedNames.contains(bareName) else { continue } // already active
            let kind: OpenSessionRow.Kind = (info.clients ?? 1) == 0 ? .orphanIdle : .orphanInUse
            orphaned.append(OpenSessionRow(
                name: bareName,
                kind: kind,
                startDir: info.startDir,
                cmd: info.cmd,
                clients: info.clients,
                created: info.created
            ))
        }
        orphaned.sort { $0.name < $1.name }

        return OpenSessionsSnapshot(active: active, orphaned: orphaned)
    }
}

/// Compact "started N ago" label from a unix-epoch creation time. Returns
/// nil when the timestamp is missing or in the future. `now` is injected so
/// the function stays pure and testable.
func relativeAge(createdEpoch: Int?, now: Date) -> String? {
    guard let createdEpoch else { return nil }
    let seconds = Int(now.timeIntervalSince1970) - createdEpoch
    if seconds < 0 { return nil }
    if seconds < 60 { return "just now" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86_400)d ago"
}
