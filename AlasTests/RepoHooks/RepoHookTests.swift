import Foundation
import Testing
@testable import Alas

struct RepoHookTests {
    @Test func eventsUseFixedRepositoryPaths() {
        #expect(RepoHookEvent.sessionOpen.relativePath == ".alas/hooks/session-open.sh")
        #expect(RepoHookEvent.worktreeCreate.relativePath == ".alas/hooks/worktree-create.sh")
    }

    @Test func trustHashBindsEventAndBytes() {
        let bytes = Data("echo hello".utf8)

        #expect(RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
            == RepoHookTrust.hash(event: .sessionOpen, bytes: bytes))
        #expect(RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
            != RepoHookTrust.hash(event: .worktreeCreate, bytes: bytes))
        #expect(RepoHookTrust.hash(event: .sessionOpen, bytes: bytes)
            != RepoHookTrust.hash(event: .sessionOpen, bytes: Data("echo hello!".utf8)))
    }

    @Test func trustHashIsLowercaseSHA256() {
        let hash = RepoHookTrust.hash(event: .sessionOpen, bytes: Data())

        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }
}
