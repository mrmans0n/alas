import Foundation
import Testing
@testable import Alas

struct MissionLegPromptBuilderTests {
    @Test("added leg prompt contains issue manifest and focused instructions")
    func buildsAddedLegPrompt() {
        let prompt = MissionLegPromptBuilder.build(
            issue: MissionFixtures.issue(),
            existingLegs: [MissionFixtures.runningLeg(projectId: "project-uuid", branch: "nacho/1842-app")],
            existingProjectNames: ["project-uuid": "Alas App"],
            projectName: "alas-sdk",
            branch: "nacho/1842-sdk",
            instructions: "Update the Swift client API."
        )

        #expect(prompt.contains("## Issue context"))
        #expect(prompt.contains("**URL:** https://github.com/acme/alas/issues/42"))
        #expect(prompt.contains("Alas App · nacho/1842-app · Running"))
        #expect(!prompt.contains("project-uuid ·"))
        #expect(prompt.contains("Update the Swift client API."))
        #expect(prompt.contains("keep the change focused"))
        #expect(!prompt.contains("Transcript"))
        #expect(!prompt.contains("diff"))
    }

    @Test("added leg manifest is ordered and retry-stable")
    func ordersManifestAndKeepsPreparedPromptStableAcrossRetry() {
        let issue = MissionFixtures.issue()
        let legs = [
            MissionFixtures.runningLeg(
                projectId: "server",
                branch: "nacho/1842-server",
                ordinal: 2
            ),
            MissionFixtures.runningLeg(
                projectId: "app",
                branch: "nacho/1842-app",
                ordinal: 0,
                state: .ready
            ),
        ]

        let prepared = MissionLegPromptBuilder.build(
            issue: issue,
            existingLegs: legs,
            projectName: "sdk",
            branch: "nacho/1842-sdk",
            instructions: "Update the client API."
        )
        let retried = MissionLegPromptBuilder.build(
            issue: issue,
            existingLegs: legs.reversed(),
            projectName: "sdk",
            branch: "nacho/1842-sdk",
            instructions: "Update the client API."
        )

        let app = try! #require(prepared.range(of: "app · nacho/1842-app · Ready"))
        let server = try! #require(prepared.range(of: "server · nacho/1842-server · Running"))
        #expect(app.lowerBound < server.lowerBound)
        #expect(prepared == retried)
    }
}

extension MissionFixtures {
    static func runningLeg(
        projectId: String,
        branch: String,
        ordinal: Int = 0,
        state: MissionLegState = .running
    ) -> MissionLeg {
        .init(
            id: .init(rawValue: "leg-\(projectId)-\(ordinal)"),
            missionID: .init(rawValue: "mission-1"),
            ordinal: ordinal,
            projectId: projectId,
            baseRef: "origin/main",
            baseRemoteName: "origin",
            branch: branch,
            destinationPath: "/tmp/\(projectId)",
            worktreeId: nil,
            worktreeLineageID: nil,
            agentId: "codex",
            acpSessionId: nil,
            initialPromptId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            pendingInitialPrompt: "Prepared prompt",
            reviewIdentity: nil,
            state: state,
            setupCheckpoint: .running,
            attentionReason: nil,
            readinessEvidence: nil,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
