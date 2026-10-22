import Foundation
import Testing
@testable import AlasPlatform

// @MainActor: ComputerUseAccess is a main-actor-isolated type.
@MainActor
struct ComputerUseAccessTests {
    private let hostPID: Int32 = 100
    private let alas = ComputerUseAppIdentity(name: "Alas", bundleID: "io.nlopez.alas", pid: 200)
    private let pidOnly = ComputerUseAppIdentity(name: "Tool", bundleID: nil, pid: 300)

    private func makeAccess(always: Set<String> = []) -> ComputerUseAccess {
        ComputerUseAccess(hostPID: hostPID, alwaysAllowed: { always })
    }

    @Test(arguments: [
        ComputerUseAppIdentity(name: "Host", bundleID: "io.nlopez.alas", pid: 100),
        ComputerUseAppIdentity(name: "Keychain", bundleID: "com.apple.keychainaccess", pid: 5),
    ])
    func blockedAppsStayBlockedDespiteGrants(app: ComputerUseAppIdentity) {
        let access = makeAccess(always: ["com.apple.keychainaccess"])
        access.record(.allowForSession, for: app, session: "s")
        #expect(access.access(for: app, session: "s") == .blocked)
    }

    @Test func otherAppsNeedApproval() {
        #expect(makeAccess().access(for: alas, session: "s") == .needsApproval)
    }

    @Test func grantScopesExpireAtTheirBoundary() {
        let access = makeAccess(always: ["com.example.always"])
        let always = ComputerUseAppIdentity(name: "A", bundleID: "com.example.always", pid: 1)

        access.record(.allowForTurn, for: alas, session: "s")
        #expect(access.access(for: alas, session: "s") == .allowed(.turn))
        access.turnEnded(session: "s")
        #expect(access.access(for: alas, session: "s") == .needsApproval)

        access.record(.allowForSession, for: alas, session: "s")
        access.turnEnded(session: "s")
        #expect(access.access(for: alas, session: "s") == .allowed(.session))
        access.sessionEnded(session: "s")
        #expect(access.access(for: alas, session: "s") == .needsApproval)

        #expect(access.access(for: always, session: "s") == .allowed(.always))

        access.record(.deny, for: alas, session: "s")
        #expect(access.access(for: alas, session: "s") == .denied)
        access.turnEnded(session: "s")
        #expect(access.access(for: alas, session: "s") == .needsApproval)
    }

    @Test func appWithoutBundleIDCannotBeAlwaysAllowed() {
        let access = makeAccess()
        access.record(.alwaysAllow, for: pidOnly, session: "s")
        #expect(access.access(for: pidOnly, session: "s") == .allowed(.session))
    }

    @Test func concurrentRequestsShareOnePendingApproval() {
        let access = makeAccess()
        let first = access.pendingApproval(session: "s", app: alas)
        let second = access.pendingApproval(session: "s", app: alas)
        #expect(first == second)
        #expect(access.pending.count == 1)
        #expect(access.resolvePending(first)?.app == alas)
        #expect(access.resolvePending(first) == nil)
    }

    @Test func stopIsPerSessionAndClearedByResumeOrSessionEnd() {
        let access = makeAccess()
        access.stop(session: "a")
        #expect(access.isStopped(session: "a"))
        #expect(!access.isStopped(session: "b"))
        access.resume(session: "a")
        #expect(!access.isStopped(session: "a"))
        access.stop(session: "a")
        access.sessionEnded(session: "a")
        #expect(!access.isStopped(session: "a"))
    }
}
