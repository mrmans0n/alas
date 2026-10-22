import Testing
@testable import AlasCore
@testable import AlasPlatform

struct ComputerUseReadinessTests {
    struct Case: Sendable {
        let enabled: Bool
        let granted: Set<ComputerUsePermission>
        let expected: ComputerUseReadiness
    }

    @Test(arguments: [
        Case(enabled: false, granted: [.screenRecording, .accessibility], expected: .disabled),
        Case(enabled: false, granted: [], expected: .disabled),
        Case(enabled: true, granted: [], expected: .missingPermissions([.screenRecording, .accessibility])),
        Case(enabled: true, granted: [.screenRecording], expected: .missingPermissions([.accessibility])),
        Case(enabled: true, granted: [.accessibility], expected: .missingPermissions([.screenRecording])),
        Case(enabled: true, granted: [.screenRecording, .accessibility], expected: .ready),
    ])
    func evaluate(_ c: Case) {
        #expect(ComputerUseReadiness.evaluate(enabled: c.enabled, granted: c.granted) == c.expected)
    }

    @Test func toolErrorsNameTheFixForTheAgent() {
        #expect(ComputerUseReadiness.ready.toolError == nil)
        #expect(ComputerUseReadiness.disabled.toolError ==
            "computer_disabled: Computer use is turned off. Ask the user to enable it in Alas Settings → Computer Use.")
        #expect(ComputerUseReadiness.missingPermissions([.screenRecording, .accessibility]).toolError ==
            "computer_permissions: Alas is missing the macOS Screen Recording and Accessibility permissions. Ask the user to grant them in Alas Settings → Computer Use.")
        #expect(ComputerUseReadiness.missingPermissions([.accessibility]).toolError ==
            "computer_permissions: Alas is missing the macOS Accessibility permission. Ask the user to grant it in Alas Settings → Computer Use.")
    }
}
