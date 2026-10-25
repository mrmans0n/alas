import Foundation
import os
import AlasModel
import AlasACP
import AlasAgentKit

private let headlessLogger = Logger(subsystem: "io.nlopez.alas", category: "AlasHost")

extension AlasCLICommandRouter {
    public static let headlessRefusal = AlasCLIResponse.error("Not available on a headless host.")

    /// Commands that act on a screen, which a headless host does not have.
    /// The local-changes review is not one: a paired Mac shows it.
    public static func isScreenBound(_ command: AlasCLIRequest.Command) -> Bool {
        switch command {
        case .open, .openAt, .preview, .computer, .workspace, .worktree(.switch):
            true
        default:
            false
        }
    }

    /// A router for `alas-host`: no UI, and screen-bound commands refused.
    public static func headless(host: AlasHost) -> AlasCLICommandRouter {
        AlasCLICommandRouter(
            host: host,
            openRelativeFile: { _, _ in },
            openExternalFile: { _, _ in },
            createWorktree: { origin, branch, base, caller in
                do {
                    let prepared = try await host.worktrees.prepareCreate(
                        projectID: origin.projectId, branch: branch, base: base, caller: caller
                    )
                    let pending = try await host.worktrees.beginCreate(prepared.request, caller: caller)
                    Task {
                        // The command has answered; nobody else hears how it ended.
                        if case .failed(let message, _) = await host.worktrees.finishCreate(pending) {
                            headlessLogger.error("Creating worktree \(branch, privacy: .private) failed: \(message, privacy: .public)")
                        }
                    }
                    return .text(["creating \(branch) at \(prepared.shownPath)"])
                } catch {
                    return .error(error.localizedDescription)
                }
            },
            deleteWorktree: { worktree, force, keepBranch, caller in
                do {
                    try await host.worktrees.delete(
                        worktree, force: force,
                        deleteBranchIfMerged: host.core.environment.configuration().worktrees.deleteBranchOnRemove && !keepBranch,
                        caller: caller
                    )
                    return .ok
                } catch {
                    return .error(error.localizedDescription)
                }
            },
            openReviewChanges: { host.reviews.openLocalChanges(in: $0) },
            openReview: { worktree, target, caller in
                switch await host.reviews.open(target, in: worktree, caller: caller) {
                case .failure(let failure):
                    return .error(failure.message)
                case .success(let opened):
                    return .text([
                        "Opened review for '\(opened.label)'.",
                        ReviewsAPI.jsonLine(["session_id": opened.record.target.draftSessionID.rawValue]),
                    ])
                }
            },
            activateApp: {},
            isHeadless: true
        )
    }
}

extension AlasHost {
    /// Answers the `alas` CLI and MCP bridge on the harness socket.
    public func serveCLI() {
        core.harness.socketServer.onCLIRequest = { [weak self] request in
            guard let self else { return .error("Alas is not available.") }
            return await AlasCLICommandRouter.headless(host: self).handle(request)
        }
    }
}
