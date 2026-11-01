import AlasComputerUseKit
import Foundation
import Testing
@testable import Alas

struct VMComputerUseRouteTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        var worktreeID: String? = "w"
        let kinds: Set<VMGuestOS>?
        var requested: VMGuestOS?
        var running: Set<VMGuestOS> = []
        let expected: VMComputerUseRoute

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "no worktree", worktreeID: nil, kinds: [.macOS], running: [.macOS], expected: .desktop),
        Case(name: "no worktree never takes a named VM to the desktop", worktreeID: nil, kinds: [], requested: .linux,
             expected: .vmMissing(guest: .linux)),
        // No VM.
        Case(name: "worktree without a VM", kinds: [], expected: .desktop),
        Case(name: "naming a macOS VM the worktree lacks", kinds: [], requested: .macOS, expected: .vmMissing(guest: .macOS)),
        Case(name: "naming a Linux VM the worktree lacks", kinds: [], requested: .linux, expected: .vmMissing(guest: .linux)),
        // One VM: used when omitted, refused when the other is named.
        Case(name: "macOS VM running here", kinds: [.macOS], running: [.macOS], expected: .guest(worktreeID: "w", guest: .macOS)),
        Case(name: "macOS VM not running here", kinds: [.macOS], expected: .vmNotRunning(worktreeID: "w", guest: .macOS)),
        Case(name: "macOS VM named", kinds: [.macOS], requested: .macOS, running: [.macOS],
             expected: .guest(worktreeID: "w", guest: .macOS)),
        Case(name: "Linux named beside only a macOS VM", kinds: [.macOS], requested: .linux, running: [.macOS],
             expected: .vmMissing(guest: .linux)),
        Case(name: "Linux VM running here", kinds: [.linux], running: [.linux], expected: .guest(worktreeID: "w", guest: .linux)),
        Case(name: "Linux VM not running here", kinds: [.linux], expected: .vmNotRunning(worktreeID: "w", guest: .linux)),
        Case(name: "macOS named beside only a Linux VM", kinds: [.linux], requested: .macOS, running: [.linux],
             expected: .vmMissing(guest: .macOS)),
        Case(name: "a VM running here counts though the registry misses it", kinds: [], running: [.macOS],
             expected: .guest(worktreeID: "w", guest: .macOS)),
        // Both VMs: never picked silently.
        Case(name: "both VMs, none named", kinds: [.macOS, .linux], expected: .ambiguous(worktreeID: "w")),
        Case(name: "both VMs, one running, none named", kinds: [.macOS], running: [.linux], expected: .ambiguous(worktreeID: "w")),
        Case(name: "both VMs running, none named", kinds: [.macOS, .linux], running: [.macOS, .linux],
             expected: .ambiguous(worktreeID: "w")),
        Case(name: "both VMs, Linux named and running", kinds: [.macOS, .linux], requested: .linux, running: [.linux],
             expected: .guest(worktreeID: "w", guest: .linux)),
        Case(name: "both VMs, macOS named while only Linux runs", kinds: [.macOS, .linux], requested: .macOS, running: [.linux],
             expected: .vmNotRunning(worktreeID: "w", guest: .macOS)),
        // Unreadable state never falls back to the desktop.
        Case(name: "unreadable VM state", kinds: nil, expected: .vmStateUnreadable(worktreeID: "w")),
        Case(name: "unreadable VM state with a VM named", kinds: nil, requested: .linux, expected: .vmStateUnreadable(worktreeID: "w")),
        Case(name: "unreadable VM state, the only VM running here", kinds: nil, running: [.macOS],
             expected: .guest(worktreeID: "w", guest: .macOS)),
        Case(name: "unreadable VM state, the named VM running here", kinds: nil, requested: .linux, running: [.linux],
             expected: .guest(worktreeID: "w", guest: .linux)),
    ]

    @Test(arguments: cases)
    func resolvesRoute(_ c: Case) {
        let route = VMComputerUseRoute.resolve(
            worktreeID: c.worktreeID, kinds: c.kinds, requested: c.requested, runningHere: { c.running.contains($0) }
        )
        #expect(route == c.expected)
    }

    private static func object(_ line: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
    }

    private static let noVM = #"{"has_vm":false,"running":false,"helper":null,"helper_error":null,"transfer_host_path":null,"transfer_guest_path":null}"#
    private static let hello = VMGuestHello(guestVersion: "1.2", accessibility: true, screenRecording: false, protocolRevision: 1)
    private static let answered = Result<VMGuestHello, VMGuestClient.Failure>.success(hello)
    private static let linuxAnswered = Result<VMGuestHello, VMGuestClient.Failure>.success(VMGuestHello(
        guestVersion: "0.1", accessibility: false, screenRecording: false, protocolRevision: 1,
        guestKind: "linux", capabilities: ["run"]))

    /// What `vm_status` reports per route: the helper only for a VM running here, and the
    /// transfer paths only where a VM is known to exist.
    @Test(arguments: [
        (VMComputerUseRoute.desktop, answered, noVM),
        (.vmStateUnreadable(worktreeID: "w"), answered,
         #"{"has_vm":null,"running":false,"helper":null,"helper_error":null,"transfer_host_path":null,"transfer_guest_path":null}"#),
        (.vmNotRunning(worktreeID: "w", guest: .macOS), answered,
         #"{"has_vm":true,"running":false,"helper":null,"helper_error":null,"transfer_host_path":"/host/t","transfer_guest_path":"/Volumes/My Shared Files/transfer"}"#),
        (.guest(worktreeID: "w", guest: .macOS), answered,
         #"{"has_vm":true,"running":true,"helper":{"version":"1.2","accessibility":true,"screen_recording":false},"helper_error":null,"transfer_host_path":"/host/t","transfer_guest_path":"/Volumes/My Shared Files/transfer"}"#),
        (.guest(worktreeID: "w", guest: .macOS), .failure(.outdated),
         #"{"has_vm":true,"running":true,"helper":null,"helper_error":"\#(VMGuestClient.Failure.outdated.message)","transfer_host_path":"/host/t","transfer_guest_path":"/Volumes/My Shared Files/transfer"}"#),
        (.vmNotRunning(worktreeID: "w", guest: .linux), answered,
         #"{"has_vm":true,"running":false,"helper":null,"helper_error":null,"transfer_host_path":"/host/t","transfer_guest_path":"/mnt/alas/transfer"}"#),
        // A Linux helper has no TCC grants to report, only what it can do.
        (.guest(worktreeID: "w", guest: .linux), linuxAnswered,
         #"{"has_vm":true,"running":true,"helper":{"version":"0.1","capabilities":["run"]},"helper_error":null,"transfer_host_path":"/host/t","transfer_guest_path":"/mnt/alas/transfer"}"#),
        (.guest(worktreeID: "w", guest: .linux), .failure(.helperUnresponsive),
         #"{"has_vm":true,"running":true,"helper":null,"helper_error":"\#(VMGuestClient.Failure.helperUnresponsive.message(for: .linux))","transfer_host_path":"/host/t","transfer_guest_path":"/mnt/alas/transfer"}"#),
    ])
    func statusReply(
        route: VMComputerUseRoute, helper: Result<VMGuestHello, VMGuestClient.Failure>, expected: String
    ) throws {
        let reply = VMComputerUseRoute.statusReply(route: route, helper: helper, transferHostPath: "/host/t")
        #expect(try Self.object(reply) == Self.object(expected))
    }

    /// With both VMs and none named, `vm_status` lists each, macOS first, naming its guest.
    @Test func statusReplyListsBothVMs() throws {
        let reply = VMComputerUseRoute.statusReply(vms: [
            (.macOS, .guest(worktreeID: "w", guest: .macOS), Self.answered, "/host/t"),
            (.linux, .vmNotRunning(worktreeID: "w", guest: .linux), nil, "/host/t-linux"),
        ])
        let expected = #"{"vms":[{"vm":"macos","has_vm":true,"running":true,"helper":{"version":"1.2","accessibility":true,"screen_recording":false},"helper_error":null,"transfer_host_path":"/host/t","transfer_guest_path":"/Volumes/My Shared Files/transfer"},{"vm":"linux","has_vm":true,"running":false,"helper":null,"helper_error":null,"transfer_host_path":"/host/t-linux","transfer_guest_path":"/mnt/alas/transfer"}]}"#
        #expect(try Self.object(reply) == Self.object(expected))
    }

    /// A Linux helper answers computer use only when its hello says so; an older one that only
    /// runs commands is asked to be updated, and one with no capabilities at all is unsupported.
    @Test(arguments: [
        (nil, VMComputerUseRoute.LinuxComputerUseDecision.unsupported),
        (["run"], .outdated),
        (["run", "computer_use"], .forward),
    ] as [([String]?, VMComputerUseRoute.LinuxComputerUseDecision)])
    func linuxComputerUseDecision(capabilities: [String]?, expected: VMComputerUseRoute.LinuxComputerUseDecision) {
        #expect(VMComputerUseRoute.linuxComputerUse(capabilities: capabilities) == expected)
    }

    /// The agent is told to update the helper: never that Linux can't do computer use.
    @Test func linuxRouteWithoutComputerUseAsksForUpdate() {
        let decision = VMComputerUseRoute.linuxComputerUse(capabilities: ["run"])
        #expect(decision.refusal == "computer_vm_helper_outdated: This Linux VM's helper can't do computer use yet. Click Update helper in its VM tab.")
        #expect(decision.refusal == VMComputerUseRoute.linuxHelperOutdatedMessage)
        #expect(VMComputerUseRoute.linuxComputerUse(capabilities: nil).refusal
            == "computer_vm_unsupported: Computer use isn't available in Linux VMs yet.")
        #expect(VMComputerUseRoute.linuxComputerUse(capabilities: ["computer_use"]).refusal == nil)
    }

    @Test func runReplyKeepsANullExitCodeForAKilledCommand() throws {
        let result = VMGuestRunResult(exitCode: nil, stdout: "a", stderr: "b", truncated: true, timedOut: true)
        let expected = #"{"exit_code":null,"stdout":"a","stderr":"b","truncated":true,"timed_out":true}"#
        #expect(try Self.object(VMComputerUseRoute.runReply(result)) == Self.object(expected))
    }
}
