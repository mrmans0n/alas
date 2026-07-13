import Testing
@testable import Alas

@Suite("ACPAdapterTarget")
struct ACPAdapterTargetTests {
    @Test("local and SSH targets have distinct identities")
    func targetIdentity() {
        let local = ACPAdapterTarget.local
        let hostA = ACPAdapterTarget.ssh(host: "build-a")
        let hostB = ACPAdapterTarget.ssh(host: "build-b")

        #expect(local != hostA)
        #expect(hostA != hostB)
        #expect(Set([local, hostA, hostB]).count == 3)
    }

    @Test("storage keys are stable and include the target identity")
    func stableStorageKeys() {
        #expect(
            ACPAdapterUpdateKey(target: .local, agentID: "codex").storageKey
                == "v2|local|5:codex")
        #expect(
            ACPAdapterUpdateKey(
                target: .ssh(host: "dev.user+ci@host:22"),
                agentID: "codex"
            ).storageKey == "v2|ssh|19:dev.user+ci@host:22|5:codex")
    }

    @Test("punctuation cannot create storage-key collisions")
    func punctuationIsCollisionSafe() {
        let keys = [
            ACPAdapterUpdateKey(target: .ssh(host: "a|1:b"), agentID: "c/d"),
            ACPAdapterUpdateKey(target: .ssh(host: "a"), agentID: "1:b|c/d"),
            ACPAdapterUpdateKey(target: .ssh(host: "user@a:22"), agentID: "codex"),
            ACPAdapterUpdateKey(target: .ssh(host: "user"), agentID: "a:22|codex"),
        ].map(\.storageKey)

        #expect(Set(keys).count == keys.count)
    }
}
