import AlasComputerUseKit
import Foundation
import Testing
@testable import Alas

struct VMComputerUseRouteTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let worktreeID: String?
        let hasVM: Bool?
        let runningHere: Bool
        let expected: VMComputerUseRoute

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "no worktree", worktreeID: nil, hasVM: true, runningHere: true, expected: .desktop),
        Case(name: "worktree without a VM", worktreeID: "w", hasVM: false, runningHere: false, expected: .desktop),
        Case(name: "no VM record ignores a running flag", worktreeID: "w", hasVM: false, runningHere: true,
             expected: .desktop),
        Case(name: "VM running here", worktreeID: "w", hasVM: true, runningHere: true,
             expected: .guest(worktreeID: "w")),
        Case(name: "VM not running here", worktreeID: "w", hasVM: true, runningHere: false,
             expected: .vmNotRunning(worktreeID: "w")),
        Case(name: "unreadable VM state never falls back to the desktop", worktreeID: "w", hasVM: nil,
             runningHere: false, expected: .vmStateUnreadable(worktreeID: "w")),
    ]

    @Test(arguments: cases)
    func resolvesRoute(_ c: Case) {
        #expect(VMComputerUseRoute.resolve(worktreeID: c.worktreeID, hasVM: c.hasVM, runningHere: c.runningHere) == c.expected)
    }

    private static func object(_ line: String) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
    }

    private static let noVM = #"{"has_vm":false,"running":false,"helper":null,"helper_error":null,"transfer_host_path":null,"transfer_guest_path":null}"#
    private static let hello = VMGuestHello(guestVersion: "1.2", accessibility: true, screenRecording: false, protocolRevision: 1)
    private static let answered = Result<VMGuestHello, VMGuestClient.Failure>.success(hello)

    /// What `vm_status` reports per route: the helper only for a VM running here, and the
    /// transfer paths only where a VM is known to exist.
    @Test(arguments: [
        (VMComputerUseRoute.desktop, answered, noVM),
        (.vmStateUnreadable(worktreeID: "w"), answered,
         #"{"has_vm":null,"running":false,"helper":null,"helper_error":null,"transfer_host_path":null,"transfer_guest_path":null}"#),
        (.vmNotRunning(worktreeID: "w"), answered,
         #"{"has_vm":true,"running":false,"helper":null,"helper_error":null,"transfer_host_path":"/host/t","transfer_guest_path":"/Volumes/My Shared Files/transfer"}"#),
        (.guest(worktreeID: "w"), answered,
         #"{"has_vm":true,"running":true,"helper":{"version":"1.2","accessibility":true,"screen_recording":false},"helper_error":null,"transfer_host_path":"/host/t","transfer_guest_path":"/Volumes/My Shared Files/transfer"}"#),
        (.guest(worktreeID: "w"), .failure(.outdated),
         #"{"has_vm":true,"running":true,"helper":null,"helper_error":"\#(VMGuestClient.Failure.outdated.message)","transfer_host_path":"/host/t","transfer_guest_path":"/Volumes/My Shared Files/transfer"}"#),
    ])
    func statusReply(
        route: VMComputerUseRoute, helper: Result<VMGuestHello, VMGuestClient.Failure>, expected: String
    ) throws {
        let reply = VMComputerUseRoute.statusReply(route: route, helper: helper, transferHostPath: "/host/t")
        #expect(try Self.object(reply) == Self.object(expected))
    }

    @Test func runReplyKeepsANullExitCodeForAKilledCommand() throws {
        let result = VMGuestRunResult(exitCode: nil, stdout: "a", stderr: "b", truncated: true, timedOut: true)
        let expected = #"{"exit_code":null,"stdout":"a","stderr":"b","truncated":true,"timed_out":true}"#
        #expect(try Self.object(VMComputerUseRoute.runReply(result)) == Self.object(expected))
    }
}
