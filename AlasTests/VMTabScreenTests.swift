import Testing
@testable import Alas

struct VMTabScreenTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        var runningHere = false
        var startingHere = false
        var slotChoice: [String]?
        var runningElsewhere: String?
        var loaded = true
        var hasVM = false
        var customizingHere = false
        var goldenAvailable = false
        var phase: GoldenImageInstaller.Phase = .idle
        var helper: VMTabScreen.HelperUpdate = .none
        var goldenHelper: VMTabScreen.HelperUpdate = .none
        let expected: VMTabScreen

        var testDescription: String { name }
    }

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
    ]

    @Test(arguments: cases)
    func resolvesScreen(_ c: Case) {
        let screen = VMTabScreen.resolve(
            runningHere: c.runningHere,
            startingHere: c.startingHere,
            slotChoice: c.slotChoice,
            runningElsewhere: c.runningElsewhere,
            loaded: c.loaded,
            hasVM: c.hasVM,
            customizingHere: c.customizingHere,
            goldenAvailable: c.goldenAvailable,
            installerPhase: c.phase,
            helper: c.helper,
            goldenHelper: c.goldenHelper
        )
        #expect(screen == c.expected)
    }
}
