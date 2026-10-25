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

    /// Password managers and credential prompts are blocked by bundle id, vendor prefix or name, even
    /// with a stored "Always"; another Alas build stays visible but can't be driven (its approval cards
    /// are not the agent's to click); terminals and System Settings stay approvable.
    @Test(arguments: [
        (ComputerUseAppIdentity(name: "Host", bundleID: "io.nlopez.alas", pid: 100), true, true),
        (ComputerUseAppIdentity(name: "Keychain", bundleID: "com.apple.keychainaccess", pid: 5), true, true),
        (ComputerUseAppIdentity(name: "1Password Safari", bundleID: "com.1password.safari", pid: 6), true, true),
        (ComputerUseAppIdentity(name: "Proton Pass", bundleID: "me.proton.pass.electron", pid: 7), true, true),
        (ComputerUseAppIdentity(name: "NordPass", bundleID: "com.nordsec.nordpass", pid: 8), true, true),
        (ComputerUseAppIdentity(name: "Password Manager Pro", bundleID: nil, pid: 9), true, true),
        (ComputerUseAppIdentity(name: "Keychain Access", bundleID: nil, pid: 10), true, true),
        (ComputerUseAppIdentity(name: "SecurityAgent", bundleID: "com.apple.SecurityAgent", pid: 11), true, true),
        (ComputerUseAppIdentity(name: "coreautha", bundleID: "com.apple.coreautha", pid: 12), true, true),
        (
            ComputerUseAppIdentity(
                name: "LocalAuthenticationUIAgent", bundleID: "com.apple.LocalAuthentication.UIAgent", pid: 13
            ), true, true
        ),
        (ComputerUseAppIdentity(name: "Alas", bundleID: "io.nlopez.alas", pid: 200), false, true),
        (ComputerUseAppIdentity(name: "Alas Dev", bundleID: "io.nlopez.alas.dev", pid: 201), false, true),
        (ComputerUseAppIdentity(name: "Alaska", bundleID: "io.nlopez.alaska", pid: 202), false, false),
        (ComputerUseAppIdentity(name: "System Settings", bundleID: "com.apple.systempreferences", pid: 14), false, false),
        (ComputerUseAppIdentity(name: "Terminal", bundleID: "com.apple.Terminal", pid: 15), false, false),
        (ComputerUseAppIdentity(name: "iTerm2", bundleID: "com.googlecode.iterm2", pid: 16), false, false),
        (ComputerUseAppIdentity(name: "Ghostty", bundleID: "com.mitchellh.ghostty", pid: 17), false, false),
        (ComputerUseAppIdentity(name: "TextEdit", bundleID: "com.apple.TextEdit", pid: 18), false, false),
    ])
    func onlyBlocklistedAppsAreBlocked(app: ComputerUseAppIdentity, blocked: Bool, inputBlocked: Bool) {
        let access = makeAccess(always: ["com.apple.keychainaccess", "com.1password.safari"])
        access.record(.allowForSession, for: app, session: "s")
        #expect(access.access(for: app, session: "s") == (blocked ? .blocked : .allowed(.session)))
        #expect(access.access(for: app, session: "s", input: true) == (inputBlocked ? .blocked : .allowed(.session)))
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

    @Test func stopIsPerSessionAndClearedOnlyByResume() {
        let access = makeAccess()
        access.record(.allowForSession, for: alas, session: "a")
        access.stop(session: "a")
        #expect(access.isStopped(session: "a"))
        #expect(!access.isStopped(session: "b"))
        access.sessionEnded(session: "a")
        #expect(access.isStopped(session: "a"))
        #expect(access.access(for: alas, session: "a") == .needsApproval)
        access.resume(session: "a")
        #expect(!access.isStopped(session: "a"))
    }

    /// coreautha runs for days, so only a process started for the prompt lets a secure field in a
    /// sheet count; a sheet that couldn't be read counts while one runs.
    @Test(arguments: [
        (["com.apple.LocalAuthentication.UIAgent", "com.apple.LocalAuthenticationRemoteService"], true, Bool?(true), true),
        (["com.apple.SecurityAgent"], true, true, true),
        (["com.apple.LocalAuthentication.UIAgent"], true, true, false),
        ([], true, true, false),
        // A save sheet while the prompt shows in another app.
        (["com.apple.LocalAuthenticationRemoteService"], true, false, false),
        (["com.apple.LocalAuthenticationRemoteService"], false, nil, false),
        (["com.apple.LocalAuthenticationRemoteService"], true, nil, true),
        (["com.apple.LocalAuthentication.UIAgent"], true, nil, false),
    ] as [(Set<String>, Bool, Bool?, Bool)])
    func credentialPromptIsToldBySecureSheetsWhileItsProcessesRun(
        running: Set<String>, untitled: Bool, secureFieldInSheet: Bool?, showing: Bool
    ) {
        #expect(ComputerUseCredentialPrompt.isShowing(
            runningBundleIDs: running, hasUntitledWindow: untitled, secureFieldInSheet: secureFieldInSheet) == showing)
    }

    /// Only an app the listing's probe reached can be said to show a prompt; one past the budget
    /// is unchecked, and nothing is said while no prompt process runs or it has no untitled window.
    @Test(arguments: [
        (["com.apple.LocalAuthenticationRemoteService"], true, true, Bool?(true), ComputerUseCredentialPrompt.Listing.showing),
        (["com.apple.LocalAuthenticationRemoteService"], true, true, nil, .showing),
        (["com.apple.LocalAuthenticationRemoteService"], true, true, false, .clear),
        (["com.apple.LocalAuthenticationRemoteService"], true, false, nil, .unchecked),
        (["com.apple.LocalAuthenticationRemoteService"], false, false, nil, .clear),
        ([], true, false, nil, .clear),
    ] as [(Set<String>, Bool, Bool, Bool?, ComputerUseCredentialPrompt.Listing)])
    func aListingOnlyClaimsPromptsInAppsItProbed(
        running: Set<String>, untitled: Bool, probed: Bool, secureFieldInSheet: Bool?, listing: ComputerUseCredentialPrompt.Listing
    ) {
        #expect(ComputerUseCredentialPrompt.listing(
            runningBundleIDs: running, hasUntitledWindow: untitled, probed: probed, secureFieldInSheet: secureFieldInSheet) == listing)
    }

    /// A card nudges when it comes up and again for a later call, at most every 10 s, and never
    /// while Alas is the active app.
    @Test(arguments: [
        (Optional<TimeInterval>.none, false, true),
        (nil, true, false),
        (9.9, false, false),
        (10, false, true),
        (60, true, false),
    ])
    func approvalCardsNudgeAtMostEveryTenSecondsWhileAlasIsInactive(sinceLast: TimeInterval?, active: Bool, nudges: Bool) {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(ComputerUseApprovalNudge.shouldNudge(
            lastNudgeAt: sinceLast.map { now.addingTimeInterval(-$0) }, now: now, appIsActive: active) == nudges)
    }
}
