import Foundation

enum AttentionProducer {
    static func harness(
        sessionID: String,
        agent: AgentKind,
        state: ActivityState,
        body: String?,
        owner: AttentionWorktreeIdentity,
        display: AttentionWorktreeDisplaySnapshot
    ) -> [AttentionObservation] {
        let awaitingKey = AttentionSourceKey(rawValue: "session:\(sessionID):awaiting")
        let permissionKey = AttentionSourceKey(rawValue: "session:\(sessionID):permission")
        let fingerprint = body?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? state.rawValue

        switch state {
        case .awaitingInput:
            return [
                .active(signal(
                    sourceKey: awaitingKey, fingerprint: fingerprint, owner: owner,
                    kind: .agentAwaiting, title: "\(agent.displayName) is waiting for input", body: body,
                    jumpTarget: .session(sessionID: sessionID), display: display
                )),
                .inactive(sourceKey: permissionKey)
            ]
        case .permissionRequest:
            return [
                .inactive(sourceKey: awaitingKey),
                .active(signal(
                    sourceKey: permissionKey, fingerprint: fingerprint, owner: owner,
                    kind: .agentPermission, title: "\(agent.displayName) needs permission", body: body,
                    jumpTarget: .session(sessionID: sessionID), display: display
                ))
            ]
        case .busy, .idle:
            return [.inactive(sourceKey: awaitingKey), .inactive(sourceKey: permissionKey)]
        }
    }

    static func script(
        failure: RunScriptFailure?,
        owner: AttentionWorktreeIdentity,
        display: AttentionWorktreeDisplaySnapshot
    ) -> [AttentionObservation] {
        guard let failure else { return [] }
        let sourceKey = AttentionSourceKey(rawValue: "script:\(failure.runID):failure")
        return [.active(signal(
            sourceKey: sourceKey, fingerprint: failure.id, owner: owner,
            kind: .runScriptFailure,
            title: "\(failure.scriptName) failed with exit code \(failure.exitCode)",
            body: output(for: failure), jumpTarget: .runScriptFailure(failureID: failure.id), display: display
        ))]
    }

    static func git(
        operation: MergeOperation?,
        changes: [ChangedFile],
        owner: AttentionWorktreeIdentity,
        display: AttentionWorktreeDisplaySnapshot
    ) -> [AttentionObservation] {
        let operationKey = AttentionSourceKey(rawValue: "git:\(owner.storageKey):operation")
        let conflictsKey = AttentionSourceKey(rawValue: "git:\(owner.storageKey):conflicts")
        var observations: [AttentionObservation] = []

        if let operation {
            observations.append(.active(signal(
                sourceKey: operationKey, fingerprint: operation.fingerprint, owner: owner,
                kind: .gitOperation, title: "\(operation.displayName) is in progress", body: nil,
                jumpTarget: .gitOperation, display: display
            )))
        } else {
            observations.append(.inactive(sourceKey: operationKey))
        }

        let paths = changes.compactMap { $0.conflict == nil ? nil : $0.path }.sorted()
        if paths.isEmpty {
            observations.append(.inactive(sourceKey: conflictsKey))
        } else {
            let count = paths.count
            observations.append(.active(signal(
                sourceKey: conflictsKey, fingerprint: paths.joined(separator: "|"), owner: owner,
                kind: .conflicts, title: "\(count) unresolved conflict\(count == 1 ? "" : "s")", body: nil,
                jumpTarget: .conflicts(path: paths.first), display: display
            )))
        }
        return observations
    }

    static func review(
        snapshot: ReviewLoopSnapshot,
        owner: AttentionWorktreeIdentity,
        display: AttentionWorktreeDisplaySnapshot
    ) -> [AttentionObservation] {
        guard let request = snapshot.reviewRequest else { return [] }
        let prefix = "review:\(owner.storageKey):\(request.remote.webURL.absoluteString):\(request.number)"
        let head = request.headSHA ?? snapshot.local.headSHA
        let target = AttentionJumpTarget.reviewRequest(number: request.number)
        let checkKey = AttentionSourceKey(rawValue: "\(prefix):checks")
        let feedbackKey = AttentionSourceKey(rawValue: "\(prefix):feedback")
        let syncKey = AttentionSourceKey(rawValue: "\(prefix):sync")
        var observations: [AttentionObservation] = []

        if request.worstCheckBucket == .fail {
            let checks = request.checks.map { "\($0.id):\($0.bucket.rawValue)" }.sorted().joined(separator: "|")
            observations.append(.active(signal(
                sourceKey: checkKey, fingerprint: "\(head)|\(checks)", owner: owner,
                kind: .failedChecks, title: "CI failed", body: nil, jumpTarget: target, display: display
            )))
        } else {
            observations.append(.inactive(sourceKey: checkKey))
        }

        if request.hasActionableFeedback {
            let threads = request.threads.filter(\.isActionable).map(\.id).sorted().joined(separator: "|")
            observations.append(.active(signal(
                sourceKey: feedbackKey, fingerprint: "\(head)|\(request.reviewDecision.rawValue)|\(threads)", owner: owner,
                kind: .actionableFeedback, title: "Review feedback needs action", body: nil, jumpTarget: target, display: display
            )))
        } else {
            observations.append(.inactive(sourceKey: feedbackKey))
        }

        switch snapshot.local.pushState {
        case .diverged, .stale:
            let title = snapshot.local.pushState == .diverged ? "Remote branch diverged" : "Remote branch is ahead"
            observations.append(.active(signal(
                sourceKey: syncKey, fingerprint: "\(head)|\(snapshot.local.pushState)", owner: owner,
                kind: .reviewSyncBlocked, title: title, body: nil, jumpTarget: target, display: display
            )))
        case .inSync, .missingUpstream, .unpushed:
            observations.append(.inactive(sourceKey: syncKey))
        }
        return observations
    }

    static func reviewReply(
        comment: ReviewDraftComment,
        owner: AttentionWorktreeIdentity,
        display: AttentionWorktreeDisplaySnapshot
    ) -> [AttentionObservation] {
        let sourceKey = AttentionSourceKey(rawValue: "review-comment:\(comment.sessionID.rawValue):\(comment.id)")
        guard comment.isActive,
              let reply = comment.allReplies.filter({ $0.author.isAgent }).max(by: { $0.createdAt < $1.createdAt })
        else { return [.inactive(sourceKey: sourceKey)] }
        let latestUserReply = comment.allReplies.filter { !$0.author.isAgent }.max { $0.createdAt < $1.createdAt }
        guard latestUserReply == nil || reply.createdAt > latestUserReply!.createdAt else {
            return [.inactive(sourceKey: sourceKey)]
        }

        return [.active(signal(
            sourceKey: sourceKey, fingerprint: reply.id, owner: owner,
            kind: .reviewReply, title: "\(reply.author.displayName) replied to review feedback", body: reply.bodyMarkdown,
            jumpTarget: .reviewComment(sessionID: comment.sessionID.rawValue, commentID: comment.id), display: display
        ))]
    }

    static func host(
        host: String,
        isDisconnected: Bool,
        owner: AttentionWorktreeIdentity,
        display: AttentionWorktreeDisplaySnapshot
    ) -> [AttentionObservation] {
        let sourceKey = AttentionSourceKey(rawValue: "host:\(owner.storageKey):\(host):disconnected")
        guard isDisconnected else { return [.inactive(sourceKey: sourceKey)] }
        return [.active(signal(
            sourceKey: sourceKey, fingerprint: host, owner: owner,
            kind: .hostDisconnected, title: "\(host) is unreachable", body: nil,
            jumpTarget: .remoteWorktree, display: display
        ))]
    }

    static func finished(
        sessionID: String,
        agent: AgentKind,
        owner: AttentionWorktreeIdentity,
        display: AttentionWorktreeDisplaySnapshot
    ) -> AttentionHistoryEvent {
        AttentionHistoryEvent(
            sourceKey: AttentionSourceKey(rawValue: "session:\(sessionID):finished"),
            fingerprint: "\(sessionID):finished", owner: owner, kind: .agentFinished,
            title: "\(agent.displayName) finished", body: nil, jumpTarget: .none, display: display
        )
    }

    private static func signal(
        sourceKey: AttentionSourceKey, fingerprint: String, owner: AttentionWorktreeIdentity,
        kind: AttentionKind, title: String, body: String?, jumpTarget: AttentionJumpTarget,
        display: AttentionWorktreeDisplaySnapshot
    ) -> AttentionSignal {
        AttentionSignal(sourceKey: sourceKey, fingerprint: fingerprint, owner: owner, kind: kind,
                        title: title, body: body, jumpTarget: jumpTarget, display: display)
    }

    private static func output(for failure: RunScriptFailure) -> String? {
        guard case .available(let text, _) = failure.capturedOutput else { return nil }
        return text
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension MergeOperation {
    var displayName: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    var fingerprint: String {
        switch self {
        case .merge(let sourceBranch): "merge:\(sourceBranch ?? "")"
        case .rebase(let plan): "rebase:\(plan.ontoBranch ?? ""):\(plan.sourceBranch ?? ""):\(plan.currentIndex.map(String.init) ?? "")"
        case .cherryPick(let sha, _): "cherry-pick:\(sha)"
        case .revert(let sha, _): "revert:\(sha)"
        }
    }
}
