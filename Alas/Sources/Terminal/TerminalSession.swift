// TerminalSession.swift
// Owns one Ghostty surface plus its surrounding metadata.
// SwiftUI views attach to the surface via NSView re-parenting; the session
// outlives the view, so switching tabs/worktrees doesn't kill the shell.

import Foundation
import AppKit

struct TerminalSessionIdentity: Hashable, Sendable {
    let worktreeId: String
    let leafId: String
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

    /// Set by HarnessService in Plan 5 — nil here.
    var harnessKind: String? = nil
    var harnessState: String? = nil   // "running" | "awaiting" | "done" | nil

    init(
        id: String,
        worktreeId: String,
        projectId: String,
        surface: AlasGhostty.SurfaceView,
        executable: String,
        args: [String]
    ) {
        self.id = id
        self.worktreeId = worktreeId
        self.projectId = projectId
        self.surface = surface
        self.executable = executable
        self.args = args
        self.createdAt = Date()
    }
}
