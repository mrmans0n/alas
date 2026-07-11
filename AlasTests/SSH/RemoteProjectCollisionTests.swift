import Foundation
import Testing
@testable import Alas

struct RemoteProjectCollisionTests {
    private func project(path: String, host: String?) -> ProjectConfig {
        ProjectConfig(id: UUID().uuidString, name: "p", path: path, color: "blue", addedAt: Date(timeIntervalSince1970: 0), host: host)
    }

    @Test func remoteRootEqualToLocalRootIsRejected() {
        #expect(throws: (any Error).self) {
            try ProjectsManager.ensureNoPathCollision(newRoot: "/srv/repo", newHost: "devbox", existing: [project(path: "/srv/repo", host: nil)])
        }
    }

    @Test func remoteRootNestedInLocalRootIsRejected() {
        #expect(throws: (any Error).self) {
            try ProjectsManager.ensureNoPathCollision(newRoot: "/srv/repo/sub", newHost: "devbox", existing: [project(path: "/srv/repo", host: nil)])
        }
    }

    @Test func localRootNestedInRemoteRootIsRejected() {
        #expect(throws: (any Error).self) {
            try ProjectsManager.ensureNoPathCollision(newRoot: "/srv/repo/sub", newHost: nil, existing: [project(path: "/srv/repo", host: "devbox")])
        }
    }

    @Test func sameRootOnDifferentHostsIsRejected() {
        #expect(throws: (any Error).self) {
            try ProjectsManager.ensureNoPathCollision(newRoot: "/srv/repo", newHost: "otherbox", existing: [project(path: "/srv/repo", host: "devbox")])
        }
    }

    @Test func disjointRootsAreAccepted() throws {
        let existing = [project(path: "/srv/repo", host: "devbox")]
        try ProjectsManager.ensureNoPathCollision(newRoot: "/srv/other", newHost: nil, existing: existing)
        try ProjectsManager.ensureNoPathCollision(newRoot: "/srv/repo-two", newHost: "devbox", existing: existing)
    }

    @Test func twoLocalProjectsMayNest() throws {
        try ProjectsManager.ensureNoPathCollision(newRoot: "/srv/repo/sub", newHost: nil, existing: [project(path: "/srv/repo", host: nil)])
    }
}
