import AlasCore
import Foundation
import Testing
@testable import Alas

/// Main actor: the updaters and their seams are main-actor isolated.
@MainActor
struct VMHelperUpdaterTests {
    /// A guest whose helper drops the connection when the script restarts it, then answers
    /// hellos from `hellos` in turn (the last one repeats). Sleeps advance a fake clock.
    @MainActor
    final class FakeLinuxGuest {
        var commands: [(command: String, timeout: Int)] = []
        var hellos: [VMGuestHello]
        var helloCalls = 0
        var now = ContinuousClock.now

        init(hellos: [VMGuestHello]) { self.hellos = hellos }

        func updater() -> LinuxVMHelperUpdater {
            LinuxVMHelperUpdater(
                runInGuest: { command, timeout in
                    self.commands.append((command, timeout))
                    throw VMGuestClient.Failure.stopped
                },
                status: {
                    self.helloCalls += 1
                    return self.hellos.count > 1 ? self.hellos.removeFirst() : self.hellos[0]
                },
                sleep: { self.now += $0 },
                now: { self.now })
        }
    }

    private static func hello(_ capabilities: [String]) -> VMGuestHello {
        VMGuestHello(guestVersion: "0.2", accessibility: false, screenRecording: false,
                     protocolRevision: VMGuestProtocol.revision, guestKind: "linux", capabilities: capabilities)
    }

    /// The whole setup goes as one root script, whose own restart drops the reply; the update is
    /// done once the restarted helper says it does computer use.
    @Test func linuxUpdateRunsTheSetupAsRootAndWaitsForComputerUse() async {
        let guest = FakeLinuxGuest(hellos: [Self.hello(["run"]), Self.hello(["run", "computer_use"])])
        let outcome = await guest.updater().run()

        #expect(outcome == .updated)
        #expect(guest.commands.count == 1)
        let sent = guest.commands[0]
        #expect(sent.timeout == 600)
        let script = LinuxGuestSetup.updateCommands(user: "alas").joined(separator: "\n")
        #expect(sent.command == "sudo sh -c " + SSHCommand.shellQuote(script))
        #expect(sent.command.contains("install -m 0755 /mnt/alas/helper/cua-driver"))
        #expect(guest.helloCalls == 2)
    }

    /// A helper that comes back without computer use fails the update after a minute.
    @Test func linuxUpdateFailsWhenComputerUseNeverComesUp() async {
        let guest = FakeLinuxGuest(hellos: [Self.hello(["run"])])
        let start = guest.now
        let outcome = await guest.updater().run()

        #expect(outcome == .failed(reason: LinuxVMHelperUpdater.Reason.noComputerUse))
        #expect(guest.now - start == .seconds(60))
    }
}
