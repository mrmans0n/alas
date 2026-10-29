import Testing
@testable import Alas

struct VMComputerUseRouteTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let worktreeID: String?
        let hasVM: Bool
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
    ]

    @Test(arguments: cases)
    func resolvesRoute(_ c: Case) {
        #expect(VMComputerUseRoute.resolve(worktreeID: c.worktreeID, hasVM: c.hasVM, runningHere: c.runningHere) == c.expected)
    }
}
