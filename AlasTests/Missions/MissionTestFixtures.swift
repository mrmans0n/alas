import Foundation
@testable import Alas

enum MissionFixtures {
    static func manualSource(
        url: String = "https://linear.app/acme/issue/ALA-42/fix-parser-crash",
        title: String = "Fix parser crash",
        body: String = "The parser crashes for malformed input."
    ) -> MissionSourceSnapshot {
        .init(
            identity: .init(providerID: .manual, stableID: url),
            canonicalURL: URL(string: url)!,
            providerLabel: URL(string: url)!.host!,
            displayReference: nil,
            repositoryLocator: nil,
            title: title,
            body: body,
            state: .unknown,
            labels: [],
            assignees: [],
            providerUpdatedAt: nil,
            capturedAt: Date(timeIntervalSince1970: 100),
            refreshError: nil,
            contentOrigin: .manual,
            isEditable: true,
            isRefreshable: false
        )
    }

    static func issue(
        number: Int = 42,
        title: String = "Fix parser crash",
        labels: [String] = ["bug", "parser"],
        capturedAt: TimeInterval = 100
    ) -> MissionIssueSnapshot {
        .init(
            identity: .init(
                provider: .github,
                host: "github.com",
                repositorySlug: "acme/alas",
                number: number
            ),
            canonicalURL: URL(string: "https://github.com/acme/alas/issues/\(number)")!,
            title: title,
            body: "The parser crashes for malformed input.",
            state: .open,
            labels: labels,
            assignees: ["nacho"],
            providerUpdatedAt: Date(timeIntervalSince1970: 90),
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            refreshError: nil
        )
    }

    static func creatingMission(
        id: String = "mission-1",
        issue: MissionIssueSnapshot = issue(),
        createdAt: TimeInterval = 100,
        baseRef: String = "origin/main",
        baseRemoteName: String? = "origin"
    ) -> MissionAggregate {
        let missionID = MissionID(rawValue: id)
        let legID = MissionLegID(rawValue: "\(id)-leg-1")
        return .init(
            mission: .init(
                id: missionID,
                title: issue.title,
                state: .creating,
                primaryLegID: legID,
                createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: createdAt),
                completedAt: nil
            ),
            issue: issue,
            legs: [leg(
                id: legID,
                missionID: missionID,
                baseRef: baseRef,
                baseRemoteName: baseRemoteName
            )],
            events: [event(id: "\(id)-event-1", missionID: missionID, legID: legID, kind: .created)]
        )
    }

    static func creatingMission(
        id: String = "mission-1",
        source: MissionSourceSnapshot,
        createdAt: TimeInterval = 100,
        baseRef: String = "origin/main",
        baseRemoteName: String? = "origin"
    ) -> MissionAggregate {
        let missionID = MissionID(rawValue: id)
        let legID = MissionLegID(rawValue: "\(id)-leg-1")
        return .init(
            mission: .init(
                id: missionID,
                title: source.title,
                state: .creating,
                primaryLegID: legID,
                createdAt: Date(timeIntervalSince1970: createdAt),
                updatedAt: Date(timeIntervalSince1970: createdAt),
                completedAt: nil
            ),
            source: source,
            legs: [leg(
                id: legID,
                missionID: missionID,
                baseRef: baseRef,
                baseRemoteName: baseRemoteName
            )],
            events: [event(id: "\(id)-event-1", missionID: missionID, legID: legID, kind: .created)]
        )
    }

    static func leg(
        id: MissionLegID,
        missionID: MissionID,
        ordinal: Int = 0,
        projectId: String = "project-1",
        baseRef: String = "origin/main",
        baseRemoteName: String? = "origin"
    ) -> MissionLeg {
        .init(
            id: id,
            missionID: missionID,
            ordinal: ordinal,
            projectId: projectId,
            baseRef: baseRef,
            baseRemoteName: baseRemoteName,
            branch: "fix/parser-crash",
            destinationPath: "/tmp/alas-mission",
            worktreeId: nil,
            worktreeLineageID: nil,
            agentId: "codex",
            acpSessionId: nil,
            initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            pendingInitialPrompt: "Fix issue #42.",
            reviewIdentity: nil,
            state: .creating,
            setupCheckpoint: .creatingWorktree,
            attentionReason: nil,
            readinessEvidence: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    static func event(
        id: String,
        missionID: MissionID = MissionID(rawValue: "mission-1"),
        legID: MissionLegID? = MissionLegID(rawValue: "mission-1-leg-1"),
        kind: MissionEventKind,
        createdAt: TimeInterval = 101
    ) -> MissionEvent {
        .init(
            id: id,
            missionID: missionID,
            legID: legID,
            kind: kind,
            message: "Mission event \(id).",
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }
}

extension MissionID {
    static let fixture = MissionID(rawValue: "fixture-mission")
}

extension MissionLegID {
    static let app = MissionLegID(rawValue: "fixture-app-leg")
    static let sdk = MissionLegID(rawValue: "fixture-sdk-leg")
}

extension MissionFixtures {
    static func twoLegMission() -> MissionAggregate {
        let createdAt = Date(timeIntervalSince1970: 100)
        let app = fixtureLeg(
            id: .app,
            ordinal: 0,
            projectID: "app-project",
            branch: "app-fix",
            destinationPath: "/tmp/fixture-app",
            worktreeID: "app-worktree",
            lineageID: "app-lineage"
        )
        let sdk = fixtureLeg(
            id: .sdk,
            ordinal: 1,
            projectID: "sdk-project",
            branch: "sdk-fix",
            destinationPath: "/tmp/fixture-sdk",
            worktreeID: "sdk-worktree",
            lineageID: "sdk-lineage"
        )
        return MissionAggregate(
            mission: .init(
                id: .fixture,
                title: "Fixture Mission",
                state: .running,
                setupCheckpoint: .running,
                primaryLegID: .app,
                createdAt: createdAt,
                updatedAt: createdAt,
                completedAt: nil
            ),
            issue: issue(),
            legs: [app, sdk],
            events: []
        )
    }

    static func fixtureLeg(
        id: MissionLegID,
        ordinal: Int,
        projectID: String,
        branch: String,
        destinationPath: String,
        worktreeID: String,
        lineageID: String
    ) -> MissionLeg {
        let timestamp = Date(timeIntervalSince1970: 100)
        return MissionLeg(
            id: id,
            missionID: .fixture,
            ordinal: ordinal,
            projectId: projectID,
            baseRef: "origin/main",
            baseRemoteName: "origin",
            branch: branch,
            destinationPath: destinationPath,
            worktreeId: worktreeID,
            worktreeLineageID: lineageID,
            agentId: "codex",
            acpSessionId: "session-\(ordinal)",
            initialPromptId: UUID(uuidString: ordinal == 0
                ? "00000000-0000-0000-0000-000000000010"
                : "00000000-0000-0000-0000-000000000011")!,
            pendingInitialPrompt: nil,
            reviewIdentity: nil,
            state: .running,
            setupCheckpoint: .running,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }
}
