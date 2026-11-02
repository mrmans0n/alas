import AlasCore
import Foundation
import Testing
@testable import Alas

struct VMTabScreenTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        var guest: VMGuestOS = .macOS
        var runningHere = false
        var startingHere = false
        var slotChoice: [String]?
        var runningElsewhere: String?
        var loaded = true
        var hasVM = false
        var customizingHere = false
        var goldenAvailable = false
        var phase: GoldenImageInstaller.Phase = .idle
        var linuxPhase: LinuxGoldenInstaller.Phase = .idle
        var helper: VMTabScreen.HelperUpdate = .none
        var goldenHelper: VMTabScreen.HelperUpdate = .none
        var pausedAt: Date?
        let expected: VMTabScreen

        var testDescription: String { name }
    }

    static let savedAt = Date(timeIntervalSince1970: 1_000_000)

    static let cases: [Case] = [
        Case(name: "running here wins over everything", runningHere: true, startingHere: true,
             slotChoice: [], runningElsewhere: "Alas Dev", hasVM: true, expected: .running(updateHelper: false)),
        Case(name: "booting", startingHere: true, slotChoice: ["a"], hasVM: true, expected: .starting),
        Case(name: "slot choice", slotChoice: ["a"], hasVM: true, expected: .slotChoice(candidates: ["a"])),
        Case(name: "running elsewhere", runningElsewhere: "Alas Dev", hasVM: true,
             expected: .runningElsewhere(label: "Alas Dev")),
        Case(name: "registry not read yet", loaded: false, expected: .loading),
        Case(name: "own VM stays stopped while a golden is customized from another tab", hasVM: true,
             phase: .awaitingSetup(build: "25A1"), expected: .stoppedWhileCustomizing),
        Case(name: "the tab customizing the golden shows its setup", hasVM: true, customizingHere: true,
             phase: .awaitingSetup(build: "25A1"), expected: .goldenSetup(build: "25A1", updateHelper: false)),
        Case(name: "own VM running here wins over customizing", runningHere: true, hasVM: true,
             customizingHere: true, phase: .awaitingSetup(build: "25A1"), expected: .running(updateHelper: false)),
        Case(name: "own VM stays stopped while a golden installs", hasVM: true,
             phase: .installing(0.4), expected: .stopped),
        Case(name: "no VM, golden awaiting setup", phase: .awaitingSetup(build: "25A1"),
             expected: .goldenSetup(build: "25A1", updateHelper: false)),
        Case(name: "no VM, golden downloading", goldenAvailable: true, phase: .downloading(0.1), expected: .setup),
        Case(name: "no VM, golden provisioning", phase: .provisioning(step: .verifying), expected: .setup),
        Case(name: "no VM, install failed", phase: .failed("offline"), expected: .setup),
        Case(name: "no VM, no golden", expected: .setup),
        Case(name: "no VM, sealed golden", goldenAvailable: true, phase: .sealed(build: "25A1"), expected: .createVM),
        Case(name: "running VM with a missing or outdated helper offers an update", runningHere: true, hasVM: true,
             helper: .available, expected: .running(updateHelper: true)),
        Case(name: "an update in progress wins over the VM restarting under it", startingHere: true, hasVM: true,
             helper: .updating, expected: .updatingHelper),
        Case(name: "an update in progress wins over the VM stopped for the patch", hasVM: true, helper: .updating,
             expected: .updatingHelper),
        Case(name: "golden with a missing or outdated helper offers an update", phase: .awaitingSetup(build: "25A1"),
             goldenHelper: .available, expected: .goldenSetup(build: "25A1", updateHelper: true)),
        Case(name: "golden helper update in progress", phase: .awaitingSetup(build: "25A1"), goldenHelper: .updating,
             expected: .updatingHelper),
        Case(name: "another tab's golden helper update leaves the own VM stopped", hasVM: true,
             phase: .awaitingSetup(build: "25A1"), goldenHelper: .updating, expected: .stoppedWhileCustomizing),
        Case(name: "a paused VM shows paused", hasVM: true, pausedAt: savedAt, expected: .paused(savedAt: savedAt)),
        Case(name: "a paused VM stays paused while a golden is customized from another tab", hasVM: true,
             phase: .awaitingSetup(build: "25A1"), pausedAt: savedAt, expected: .paused(savedAt: savedAt)),
        Case(name: "a paused VM resuming shows starting", startingHere: true, hasVM: true, pausedAt: savedAt,
             expected: .starting),
        Case(name: "a VM running here wins over a paused record", runningHere: true, hasVM: true, pausedAt: savedAt,
             expected: .running(updateHelper: false)),
        Case(name: "Linux, never paused", guest: .linux, hasVM: true, pausedAt: savedAt, expected: .stopped),
        Case(name: "Linux, no image yet", guest: .linux, expected: .setup),
        Case(name: "Linux, image downloading", guest: .linux, goldenAvailable: true,
             linuxPhase: .downloading(0.3), expected: .setup),
        Case(name: "Linux, download being checked", guest: .linux, linuxPhase: .checking, expected: .setup),
        Case(name: "Linux, setup failed", guest: .linux, linuxPhase: .failed("offline"), expected: .setup),
        Case(name: "Linux, sealed image", guest: .linux, goldenAvailable: true,
             linuxPhase: .sealed(serial: "20260101"), expected: .createVM),
        Case(name: "Linux ignores a macOS golden awaiting setup", guest: .linux,
             phase: .awaitingSetup(build: "25A1"), goldenHelper: .available, expected: .setup),
        Case(name: "Linux VM stopped", guest: .linux, hasVM: true, phase: .awaitingSetup(build: "25A1"),
             linuxPhase: .converting(0.5), expected: .stopped),
        Case(name: "Linux VM running", guest: .linux, runningHere: true, hasVM: true, helper: .available,
             expected: .running(updateHelper: true)),
        Case(name: "Linux VM updating its helper", guest: .linux, runningHere: true, hasVM: true, helper: .updating,
             expected: .updatingHelper),
        Case(name: "Linux VM running elsewhere", guest: .linux, runningElsewhere: "Alas Dev", hasVM: true,
             expected: .runningElsewhere(label: "Alas Dev")),
    ]

    @Test(arguments: cases)
    func resolvesScreen(_ c: Case) {
        let screen = VMTabScreen.resolve(
            guest: c.guest,
            runningHere: c.runningHere,
            startingHere: c.startingHere,
            slotChoice: c.slotChoice,
            runningElsewhere: c.runningElsewhere,
            loaded: c.loaded,
            hasVM: c.hasVM,
            customizingHere: c.customizingHere,
            goldenAvailable: c.goldenAvailable,
            installerPhase: c.phase,
            linuxInstallerPhase: c.linuxPhase,
            helper: c.helper,
            goldenHelper: c.goldenHelper,
            pausedAt: c.pausedAt
        )
        #expect(screen == c.expected)
    }

    static let pausedAges: [(TimeInterval, String)] = [
        (0, "saved just now"),
        (59, "saved just now"),
        (60, "saved 1 min ago"),
        (3599, "saved 59 min ago"),
        (3600, "saved 1 h ago"),
        (176_400, "saved 2 d ago"),
    ]

    @Test(arguments: pausedAges)
    func pausedStatusSaysWhenItWasSaved(_ elapsed: TimeInterval, _ expected: String) {
        #expect(VMTabScreen.pausedAge(savedAt: Self.savedAt, now: Self.savedAt + elapsed) == expected)
    }

    @Test(arguments: [
        (VMDriver.idle, VMDriverStatus(tone: .running, title: "Running", details: [], action: .takeOver)),
        (.agent(sessionID: "s1", tool: "computer_click", at: Date(timeIntervalSince1970: 100)),
         VMDriverStatus(tone: .running, title: "Claude is driving", details: ["computer_click 12s ago"], action: .takeOver)),
        (.agent(sessionID: "s1", tool: "vm_run", at: Date(timeIntervalSince1970: 112.9)),
         VMDriverStatus(tone: .running, title: "Claude is driving", details: ["vm_run 0s ago"], action: .takeOver)),
        (.user, VMDriverStatus(tone: .busy, title: "You're driving", details: ["agent calls are on hold"], action: .handBack)),
    ])
    func driverStatus(_ driver: VMDriver, _ expected: VMDriverStatus) {
        #expect(VMDriverStatus.make(driver: driver, agentName: "Claude", now: Date(timeIntervalSince1970: 112.5)) == expected)
    }

    struct BadgeCase: CustomTestStringConvertible, Sendable {
        let name: String
        var drivingApp: String?
        var drivingVM = false
        var stopped = false
        var vmStarting = false
        var waitingForSlot = false
        var userDriving = false
        let expected: ComputerUseBadge.Label?

        var testDescription: String { name }
    }

    // The badge has no suite of its own; its labels follow the VM states this suite resolves.
    @Test(arguments: [
        BadgeCase(name: "idle session", expected: nil),
        BadgeCase(name: "desktop driver", drivingApp: "Safari", expected: .init(text: "Using Safari", accent: true)),
        BadgeCase(name: "VM driver", drivingVM: true, expected: .init(text: "Using the VM", accent: true)),
        BadgeCase(name: "desktop driver wins over its VM", drivingApp: "Safari", drivingVM: true, userDriving: true,
                  expected: .init(text: "Using Safari", accent: true)),
        BadgeCase(name: "stopped wins", drivingVM: true, stopped: true, vmStarting: true, userDriving: true,
                  expected: .init(text: "Computer use stopped", accent: false)),
        BadgeCase(name: "waiting on the auto-start", vmStarting: true, expected: .init(text: "Starting the VM", accent: true)),
        BadgeCase(name: "waiting on a slot card", vmStarting: true, waitingForSlot: true,
                  expected: .init(text: "Waiting for a VM slot", accent: true)),
        BadgeCase(name: "the user took its VM over", drivingVM: true, userDriving: true,
                  expected: .init(text: "You're driving the VM", accent: false)),
    ])
    func badgeLabel(_ c: BadgeCase) {
        let label = ComputerUseBadge.label(
            drivingApp: c.drivingApp, drivingVM: c.drivingVM, stopped: c.stopped, vmStarting: c.vmStarting,
            waitingForSlot: c.waitingForSlot, userDriving: c.userDriving
        )
        #expect(label == c.expected)
    }
}
