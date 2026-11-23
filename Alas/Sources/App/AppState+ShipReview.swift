import Foundation

/// Review before push: the actions the Ship popover, the review drawer and
/// the verdict banner offer, forwarded to `ShipReviewer`, and its stop notices.
extension AppState {
    /// Opens the latest filed round's review session and focuses its worktree.
    func openShipReview(_ id: ShipReviewID) {
        guard let reviewSessionID = core.shipReviewer.record(for: id)?.rounds.last(where: { $0.reviewSessionID != nil })?.reviewSessionID,
              let record = try? core.reviewSessions.load(id: reviewSessionID)
        else {
            inAppNotifications.post("Couldn't find the review for this push.", severity: .error, worktreeID: id.worktreeID)
            return
        }
        selectWorktree(id: id.worktreeID)
        let tab = tabs.openOrFocusReviewSession(worktreeId: id.worktreeID, record: record)
        activateWorktreeCenterTab(worktreeId: id.worktreeID, tabId: tab.id)
    }

    /// Opens the reviewer's ACP session while it is still live.
    func openReviewerSession(_ id: ShipReviewID) {
        guard let sessionID = core.shipReviewer.record(for: id)?.reviewerSessionID,
              let worktree = worktree(withId: id.worktreeID)
        else { return }
        selectWorktree(id: worktree.id)
        Task { @MainActor [weak self] in
            await self?.openExistingACPSession(sessionId: sessionID, worktree: worktree)
        }
    }

    /// "Ship without review" and "Ship anyway": the head Ship would push now
    /// passes, and a held-back push goes out.
    func shipWithoutReview(_ id: ShipReviewID) {
        let shipReviewer = core.shipReviewer
        guard let effects = shipReviewer.effects, let record = shipReviewer.record(for: id) else { return }
        clearShipReviewStopActivity(id)
        Task { @MainActor [weak self] in
            do {
                let head = try await effects.shipHead(id, record.pending)
                shipReviewer.allow(id, headSHA: head)
            } catch {
                self?.inAppNotifications.post(
                    "Couldn't read the commit to push: \(error.localizedDescription)",
                    severity: .error,
                    worktreeID: id.worktreeID
                )
            }
        }
    }

    /// The verdict banner's "Ship anyway": exactly the head that round reviewed
    /// passes, and the held-back push goes out.
    func shipReviewedHead(_ id: ShipReviewID, headSHA: String) {
        clearShipReviewStopActivity(id)
        core.shipReviewer.allow(id, headSHA: headSHA)
    }

    func retryShipReview(_ id: ShipReviewID) {
        clearShipReviewStopActivity(id)
        core.shipReviewer.retry(id)
    }

    func stopShipReview(_ id: ShipReviewID) {
        clearShipReviewStopActivity(id)
        core.shipReviewer.cancel(id)
    }

    /// "Send to session": the latest round's open findings go to the owning session.
    func sendShipReviewFindings(_ id: ShipReviewID) {
        clearShipReviewStopActivity(id)
        core.shipReviewer.sendFindings(id)
    }

    /// Clears the attention `notifyShipReviewStop` set on the owning session
    /// once the user handles the stop. Live activity the session reported
    /// since (a new turn, a permission prompt) is left alone. Call before the
    /// action moves the record off its stop.
    private func clearShipReviewStopActivity(_ id: ShipReviewID) {
        guard let record = core.shipReviewer.record(for: id), case let .stopped(stop) = record.phase,
              let activity = harness.activityBySession[id.sessionID],
              activity.state == .awaitingInput,
              activity.lastBody == ShipReviewPresentation.stopMessage(stop, maxRounds: record.maxRounds)
        else { return }
        harness.finishExternalActivity(
            sessionId: id.sessionID,
            owner: .worktree(id.worktreeID),
            agent: activity.agent,
            recordIdleTransition: false
        )
    }

    /// A stopped review: nothing was pushed until the user acts. Posted like
    /// a shepherd escalation, as a notification plus the session's attention.
    func notifyShipReviewStop(_ id: ShipReviewID, message: String) {
        guard let resolved = projectAndWorktree(withWorktreeId: id.worktreeID) else { return }
        let title = "Review before push"
        let owner = SessionOwnerID.worktree(id.worktreeID)
        let agent = shepherdAgentKind(sessionID: id.sessionID, worktreeID: id.worktreeID)
        harness.notifications.notifyAlas(
            body: message,
            title: title,
            agent: agent,
            projectId: resolved.project.id,
            worktreeId: resolved.worktree.id,
            sessionId: id.sessionID,
            owner: owner
        )
        harness.setExternalActivity(
            sessionId: id.sessionID,
            owner: owner,
            agent: agent,
            state: .awaitingInput,
            body: message,
            requiresUserInput: true
        )
    }
}
