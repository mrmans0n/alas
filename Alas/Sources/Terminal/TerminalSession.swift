// TerminalSession.swift
// Owns one Ghostty surface plus its surrounding metadata.
// SwiftUI views attach to the surface via NSView re-parenting; the session
// outlives the view, so switching tabs/worktrees doesn't kill the shell.

import Foundation
import AppKit

struct TerminalSessionIdentity: Sendable {
    let worktreeId: String
    let projectPath: String?
    let leafId: String

    init(worktreeId: String, projectPath: String? = nil, leafId: String) {
        self.worktreeId = worktreeId
        self.projectPath = projectPath
        self.leafId = leafId
    }
}

extension TerminalSessionIdentity: Hashable {
    static func == (lhs: TerminalSessionIdentity, rhs: TerminalSessionIdentity) -> Bool {
        lhs.worktreeId == rhs.worktreeId && lhs.leafId == rhs.leafId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(worktreeId)
        hasher.combine(leafId)
    }
}

@MainActor
final class TerminalSession {
    let id: String                // matches Tab.id (UUID string)
    let worktreeId: String
    let projectId: String
    let createdAt: Date

    let surface: AlasGhostty.SurfaceView
    let executable: String
    let args: [String]
    let zmxSessionName: String?
    let remoteHost: String?

    /// Set by HarnessService in Plan 5 — nil here.
    var harnessKind: String? = nil
    var harnessState: String? = nil   // "running" | "awaiting" | "done" | nil

    init(
        id: String,
        worktreeId: String,
        projectId: String,
        surface: AlasGhostty.SurfaceView,
        executable: String,
        args: [String],
        zmxSessionName: String? = nil,
        remoteHost: String? = nil
    ) {
        self.id = id
        self.worktreeId = worktreeId
        self.projectId = projectId
        self.surface = surface
        self.executable = executable
        self.args = args
        self.zmxSessionName = zmxSessionName
        self.remoteHost = remoteHost
        self.createdAt = Date()
    }
}
