import Foundation
import Observation
import Testing
@testable import Alas

private struct FixedVersionGGRunner: GGCommandRunning {
    let version: String?
    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        guard args == ["--version"], let version else {
            return ProcessResult(exitCode: 127, stdout: "", stderr: "not found")
        }
        return ProcessResult(exitCode: 0, stdout: "gg \(version)\n", stderr: "")
    }
}

private struct HelpGGRunner: GGCommandRunning {
    let version: String?
    let root: String?
    let split: String?
    let unstack: String?
    let sc: String?
    let sync: String?

    init(
        version: String? = "1.0.0",
        root: String? = nil,
        split: String?,
        unstack: String?,
        sc: String? = nil,
        sync: String? = nil
    ) {
        self.version = version
        self.root = root
        self.split = split
        self.unstack = unstack
        self.sc = sc
        self.sync = sync
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        switch args {
        case ["--version"]:
            guard let version else { break }
            return ProcessResult(exitCode: 0, stdout: "gg \(version)\n", stderr: "")
        case ["--help"]:
            guard let root else { break }
            return ProcessResult(exitCode: 0, stdout: root, stderr: "")
        case ["split", "--help"]:
            guard let split else { break }
            return ProcessResult(exitCode: 0, stdout: split, stderr: "")
        case ["unstack", "--help"]:
            guard let unstack else { break }
            return ProcessResult(exitCode: 0, stdout: unstack, stderr: "")
        case ["sc", "--help"]:
            guard let sc else { break }
            return ProcessResult(exitCode: 0, stdout: sc, stderr: "")
        case ["sync", "--help"]:
            guard let sync else { break }
            return ProcessResult(exitCode: 0, stdout: sync, stderr: "")
        default:
            break
        }
        return ProcessResult(exitCode: 127, stdout: "", stderr: "not found")
    }
}

private final class InvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
struct GGAvailabilityTests {
    @Test func splitCapabilityRequiresBothFlags() async {
        let service = GGService(
            runner: HelpGGRunner(split: "--describe --plan-json", unstack: "--keep-current")
        )
        #expect(
            await service.probeCapabilities()
                == GGCapabilities(structuredSplit: true, keepCurrentUnstack: true)
        )

        let oldService = GGService(runner: HelpGGRunner(split: "--describe", unstack: ""))
        #expect(
            await oldService.probeCapabilities()
                == GGCapabilities(structuredSplit: false, keepCurrentUnstack: false)
        )
    }

    @Test func capabilityProbeReturnsFalseWhenHelpCommandsFail() async {
        let service = GGService(runner: HelpGGRunner(split: nil, unstack: nil))

        #expect(
            await service.probeCapabilities()
                == GGCapabilities(structuredSplit: false, keepCurrentUnstack: false)
        )
    }

    @Test func clientOperationCapabilityUsesRootHelpAndDefaultsOff() async {
        let current = GGService(runner: HelpGGRunner(
            root: "--client-operation-id <ID>", split: "", unstack: ""
        ))
        #expect((await current.probeCapabilities()).clientOperationID)

        let old = GGService(runner: HelpGGRunner(root: "--verbose", split: "", unstack: ""))
        #expect(!(await old.probeCapabilities()).clientOperationID)
    }

    @Test func stagedOnlyAmendCapabilityUsesScHelpAndDefaultsOff() async {
        let current = GGService(runner: HelpGGRunner(
            split: "", unstack: "", sc: "--staged-only"
        ))
        #expect((await current.probeCapabilities()).stagedOnlyAmend)

        let old = GGService(runner: HelpGGRunner(split: "", unstack: "", sc: "--message"))
        #expect(!(await old.probeCapabilities()).stagedOnlyAmend)
    }

    @Test func syncJSONLCapabilityUsesSyncHelpAndDefaultsOff() async {
        let current = GGService(runner: HelpGGRunner(
            split: "", unstack: "", sync: "--json --jsonl"
        ))
        #expect((await current.probeCapabilities()).syncJSONL)

        let old = GGService(runner: HelpGGRunner(
            split: "", unstack: "", sync: "--json"
        ))
        #expect(!(await old.probeCapabilities()).syncJSONL)
    }

    @Test func probePopulatesVersionAndMCPPath() async {
        let availability = GGAvailability()
        await availability.probe(
            service: GGService(runner: FixedVersionGGRunner(version: "0.9.9")),
            which: { name in name == "gg-mcp" ? "/opt/homebrew/bin/gg-mcp" : nil },
            force: true
        )
        #expect(availability.version == "0.9.9")
        #expect(availability.isInstalled)
        #expect(availability.ggMCPBinaryPath == "/opt/homebrew/bin/gg-mcp")
    }

    @Test func missingMCPBinaryYieldsNilWithoutAffectingGG() async {
        let availability = GGAvailability()
        await availability.probe(
            service: GGService(runner: FixedVersionGGRunner(version: "0.9.9")),
            which: { _ in nil },
            force: true
        )
        #expect(availability.isInstalled)
        #expect(availability.ggMCPBinaryPath == nil)
    }

    @Test func nonForceProbeIsCachedAfterFirstRun() async {
        let availability = GGAvailability()
        await availability.probe(
            service: GGService(runner: FixedVersionGGRunner(version: "1.0.0")),
            which: { _ in "/first/gg-mcp" },
            force: true
        )
        // Second, non-force probe must not overwrite cached results.
        await availability.probe(
            service: GGService(runner: FixedVersionGGRunner(version: "9.9.9")),
            which: { _ in "/second/gg-mcp" },
            force: false
        )
        #expect(availability.version == "1.0.0")
        #expect(availability.ggMCPBinaryPath == "/first/gg-mcp")
    }

    @Test func forcedProbeUpdatesCapabilitiesWithDetectedVersion() async {
        let availability = GGAvailability()
        await availability.probe(
            service: GGService(
                runner: HelpGGRunner(
                    version: "1.0.0",
                    split: "--describe --plan-json",
                    unstack: "--keep-current"
                )
            ),
            which: { _ in nil },
            force: true
        )
        #expect(
            availability.capabilities
                == GGCapabilities(structuredSplit: true, keepCurrentUnstack: true)
        )

        await availability.probe(
            service: GGService(
                runner: HelpGGRunner(version: "2.0.0", split: "--describe", unstack: "")
            ),
            which: { _ in nil },
            force: true
        )
        #expect(availability.version == "2.0.0")
        #expect(
            availability.capabilities
                == GGCapabilities(structuredSplit: false, keepCurrentUnstack: false)
        )
    }

    @Test func unchangedCapabilityProbeDoesNotInvalidateObservers() async {
        let availability = GGAvailability()
        let service = GGService(
            runner: HelpGGRunner(split: "--describe --plan-json", unstack: "--keep-current")
        )
        await availability.probe(service: service, which: { _ in nil }, force: true)

        let invalidations = InvalidationCounter()
        withObservationTracking {
            _ = availability.capabilities
        } onChange: {
            invalidations.increment()
        }

        await availability.probe(service: service, which: { _ in nil }, force: true)
        #expect(invalidations.count == 0)
    }
}
