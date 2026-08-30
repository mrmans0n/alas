// TerminalSession.swift
// Owns one Ghostty surface plus its surrounding metadata.
// SwiftUI views attach to the surface via NSView re-parenting; the session
// outlives the view, so switching tabs/worktrees doesn't kill the shell.

import Foundation
import AppKit

struct TerminalSessionIdentity: Sendable {
    let owner: SessionOwnerID
    let projectPath: String?
    let leafId: String

    init(worktreeId: String, projectPath: String? = nil, leafId: String) {
        self.init(owner: .worktree(worktreeId), projectPath: projectPath, leafId: leafId)
    }

    init(owner: SessionOwnerID, projectPath: String? = nil, leafId: String) {
        self.owner = owner
        self.projectPath = projectPath
        self.leafId = leafId
    }

    /// Compatibility view for paths that still operate only on legacy
    /// Worktrees. New checkout paths must use `owner` rather than collapsing
    /// their location-qualified identity into a string.
    var worktreeId: String {
        switch owner {
        case .worktree(let id): id
        case .workspaceCheckout: owner.storageKey
        }
    }

    var zmxSessionName: String {
        ZmxSessionName.derive(owner: owner, leafId: leafId)
    }
}

extension TerminalSessionIdentity: Hashable {
    static func == (lhs: TerminalSessionIdentity, rhs: TerminalSessionIdentity) -> Bool {
        lhs.owner == rhs.owner && lhs.leafId == rhs.leafId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(owner)
        hasher.combine(leafId)
    }
}

/// Immutable launch and restoration boundary for a checkout-owned terminal.
/// It intentionally contains no focused member or Project data: focus can
/// change repository panes but never retarget a shared shell.
struct WorkspaceTerminalContext: Sendable, Equatable {
    let checkoutID: UUID
    let executionLocation: ExecutionLocation
    let rootPath: String
    let branch: String
    let manifestPath: String
    let startupScript: String

    init(
        checkoutID: UUID,
        executionLocation: ExecutionLocation,
        rootPath: String,
        branch: String,
        manifestPath: String,
        startupScript: String = ""
    ) {
        self.checkoutID = checkoutID
        self.executionLocation = executionLocation.normalized
        self.rootPath = rootPath
        self.branch = branch
        self.manifestPath = manifestPath
        self.startupScript = startupScript
    }

    var owner: SessionOwnerID { .workspaceCheckout(checkoutID, executionLocation) }
}

@MainActor
final class TerminalSession {
    let id: String                // matches Tab.id (UUID string)
    let owner: SessionOwnerID
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
        self.owner = .worktree(worktreeId)
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

    init(
        id: String,
        owner: SessionOwnerID,
        surface: AlasGhostty.SurfaceView,
        executable: String,
        args: [String],
        zmxSessionName: String? = nil,
        remoteHost: String? = nil
    ) {
        self.id = id
        self.owner = owner
        self.worktreeId = owner.storageKey
        self.projectId = ""
        self.surface = surface
        self.executable = executable
        self.args = args
        self.zmxSessionName = zmxSessionName
        self.remoteHost = remoteHost
        self.createdAt = Date()
    }
}
