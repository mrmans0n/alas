import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct WorktreeCleanupFixtureTests {
    @Test func fixtureKeepsPersistenceInMemoryAndRemovesItsEntireTemporaryTree() async throws {
        let fixture = try await makeCleanupFixture(worktreeCount: 2)

        #expect(fixture.state.projectsManager.projects == [fixture.project])
        #expect(fixture.persistenceReadPaths.contains(fixture.attentionStoreURL.path))
        #expect(!fixture.persistenceReadPaths.contains(Paths.attentionEventsFile.path))
        #expect(FileManager.default.fileExists(atPath: fixture.temporaryRoot.path))

        try fixture.removeFiles()

        #expect(!FileManager.default.fileExists(atPath: fixture.temporaryRoot.path))
    }
}
