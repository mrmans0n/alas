import Testing
import Foundation
@testable import Alas

struct GitTypesTests {
    @Test func worktreeIdIsStable() {
        let a = Worktree(id: "x", projectId: "p", name: "main", branch: "main",
                         path: URL(fileURLWithPath: "/tmp/a"), status: .clean,
                         lastActivity: Date(timeIntervalSince1970: 0))
        let b = Worktree(id: "x", projectId: "p", name: "main", branch: "main",
                         path: URL(fileURLWithPath: "/tmp/a"), status: .clean,
                         lastActivity: Date(timeIntervalSince1970: 0))
        #expect(a == b)
    }
}
