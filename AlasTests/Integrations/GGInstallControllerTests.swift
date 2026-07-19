import Testing
@testable import Alas

@MainActor
struct GGInstallControllerTests {
    @Test func successfulInstallReachesSucceededAndReprobes() async {
        var probed = false
        let controller = GGInstallController(
            runInstall: { ProcessResult(exitCode: 0, stdout: "installed", stderr: "") },
            reprobe: {
                probed = true
                return true
            }
        )
        await controller.installAndWait()
        #expect(controller.phase == .succeeded)
        #expect(probed)
    }

    @Test func brewFailureSurfacesStderr() async {
        let controller = GGInstallController(
            runInstall: { ProcessResult(exitCode: 1, stdout: "", stderr: "no tap") },
            reprobe: { true }
        )
        await controller.installAndWait()
        #expect(controller.phase == .failed("no tap"))
    }

    @Test func installedButNotOnPathFails() async {
        let controller = GGInstallController(
            runInstall: { ProcessResult(exitCode: 0, stdout: "", stderr: "") },
            reprobe: { false }
        )
        await controller.installAndWait()
        #expect(controller.phase == .failed("gg is still not on PATH after install."))
    }
}
