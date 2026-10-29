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
        let expected: VMTabScreen

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "running here wins over everything", runningHere: true, startingHere: true,
             slotChoice: [], runningElsewhere: "Alas Dev", hasVM: true, expected: .running),
        Case(name: "booting", startingHere: true, slotChoice: ["a"], hasVM: true, expected: .starting),
        Case(name: "slot choice", slotChoice: ["a"], hasVM: true, expected: .slotChoice(candidates: ["a"])),
        Case(name: "running elsewhere", runningElsewhere: "Alas Dev", hasVM: true,
             expected: .runningElsewhere(label: "Alas Dev")),
        Case(name: "registry not read yet", loaded: false, expected: .loading),
        Case(name: "own VM stays stopped while a golden is customized from another tab", hasVM: true,
             phase: .awaitingSetup(build: "25A1"), expected: .stoppedWhileCustomizing),
        Case(name: "the tab customizing the golden shows its setup", hasVM: true, customizingHere: true,
             phase: .awaitingSetup(build: "25A1"), expected: .goldenSetup(build: "25A1")),
        Case(name: "own VM running here wins over customizing", runningHere: true, hasVM: true,
             customizingHere: true, phase: .awaitingSetup(build: "25A1"), expected: .running),
        Case(name: "own VM stays stopped while a golden installs", hasVM: true,
             phase: .installing(0.4), expected: .stopped),
        Case(name: "no VM, golden awaiting setup", phase: .awaitingSetup(build: "25A1"),
             expected: .goldenSetup(build: "25A1")),
        Case(name: "no VM, golden downloading", goldenAvailable: true, phase: .downloading(0.1), expected: .setup),
        Case(name: "no VM, install failed", phase: .failed("offline"), expected: .setup),
        Case(name: "no VM, no golden", expected: .setup),
        Case(name: "no VM, sealed golden", goldenAvailable: true, phase: .sealed(build: "25A1"), expected: .createVM),
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
            installerPhase: c.phase
        )
        #expect(screen == c.expected)
    }
}
