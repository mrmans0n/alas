import Foundation
import Testing
@testable import Alas

struct RemoteLastActivityTests {
    @Test func parsesEpochSeconds() {
        #expect(WorktreeService.date(fromEpochOutput: "1752249600\n") == Date(timeIntervalSince1970: 1_752_249_600))
    }
    @Test func rejectsInvalidEpochs() {
        #expect(WorktreeService.date(fromEpochOutput: "bad") == nil)
        #expect(WorktreeService.date(fromEpochOutput: "") == nil)
    }

    @Test func parsesOnlyPositiveRemoteCreationEpochs() {
        #expect(WorktreeService.remoteCreationDate(fromEpochOutput: "1752249500\n") == Date(timeIntervalSince1970: 1_752_249_500))
        #expect(WorktreeService.remoteCreationDate(fromEpochOutput: "0\n") == nil)
        #expect(WorktreeService.remoteCreationDate(fromEpochOutput: "bad") == nil)
    }

    @Test func remoteCreationProbeUsesTheWorktreeGitFileAndPortableStat() {
        let command = WorktreeService.remoteCreationDateCommand(path: "/srv/alas/work tree")

        #expect(command.contains("/srv/alas/work tree/.git"))
        #expect(command.contains("stat -c %W"))
        #expect(command.contains("stat -f %B"))
    }

    @Test func remoteLineageProbePersistsARandomMarkerInTheGitDirectory() {
        let command = WorktreeService.remoteLineageIDCommand(
            path: "/srv/alas/work tree",
            candidateID: "lineage-123"
        )

        #expect(command.contains("git -C \"$p\" rev-parse --absolute-git-dir"))
        #expect(command.contains("alas-worktree-lineage"))
        #expect(command.contains("set -C"))
        #expect(command.contains("lineage-123"))
        #expect(WorktreeService.normalizedLineageID("lineage-123\n") == "lineage-123")
        #expect(WorktreeService.normalizedLineageID("\n") == nil)
    }
}
