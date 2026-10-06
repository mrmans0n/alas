import Foundation
import Testing
@testable import Alas

@MainActor
struct ACPAgentModelCatalogTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-model-catalog-\(UUID().uuidString).json")
    }

    @Test func remembersEachAgentsLastListAcrossLaunches() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let opus = ACPAgentModelCatalog.Model(id: "opus", name: "Opus")
        let sonnet = ACPAgentModelCatalog.Model(id: "sonnet", name: "Sonnet")

        let first = ACPAgentModelCatalog(fileURL: file)
        first.record(agentID: "claude", models: [opus, sonnet])
        first.record(agentID: "gemini", models: [ACPAgentModelCatalog.Model(id: "flash", name: "Flash")])
        // A later connection that lists fewer models replaces the list; it
        // is the agent's current answer, not a merge of every past one.
        first.record(agentID: "claude", models: [opus])

        let second = ACPAgentModelCatalog(fileURL: file)
        #expect(second.models(for: "claude") == [opus])
        #expect(second.models(for: "gemini").map(\.id) == ["flash"])
        #expect(second.models(for: "codex").isEmpty)
    }

    /// Discovery must not present a list from an earlier launch as current,
    /// and a later empty report must not demote models confirmed this run.
    @Test func tracksWhatEachAgentReportedDuringThisLaunch() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let opus = ACPAgentModelCatalog.Model(id: "opus", name: "Opus")
        ACPAgentModelCatalog(fileURL: file).record(agentID: "claude", models: [opus])

        let relaunched = ACPAgentModelCatalog(fileURL: file)
        #expect(relaunched.models(for: "claude") == [opus])
        #expect(relaunched.launchReport(for: "claude") == .notObserved)

        relaunched.record(agentID: "pi", models: [])
        #expect(relaunched.launchReport(for: "pi") == .advertisedNone)

        // The same list as last launch still counts as confirmed now.
        relaunched.record(agentID: "claude", models: [opus])
        relaunched.record(agentID: "claude", models: [])
        #expect(relaunched.launchReport(for: "claude") == .advertisedModels)
        #expect(relaunched.launchModels(for: "claude", host: nil) == [opus])
        #expect(relaunched.launchModels(for: "pi", host: nil) == [])

        // Another host may run a different adapter: nothing it reported
        // vouches for this Mac, and vice versa.
        let sonnet = ACPAgentModelCatalog.Model(id: "sonnet", name: "Sonnet")
        relaunched.record(agentID: "claude", models: [sonnet], host: "build-box")
        #expect(relaunched.launchModels(for: "claude", host: "build-box") == [sonnet])
        #expect(relaunched.launchModels(for: "claude", host: nil) == [opus])
        #expect(relaunched.launchModels(for: "claude", host: "other-box") == nil)
    }

    /// An agent that reports nothing on one connection — a failed provider
    /// lookup, say — must not erase what it listed before, or the schedule
    /// editor loses its choices until the next successful session.
    @Test func anEmptyListDoesNotEraseAnEarlierOne() {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let catalog = ACPAgentModelCatalog(fileURL: file)
        let opus = ACPAgentModelCatalog.Model(id: "opus", name: "Opus")
        catalog.record(agentID: "claude", models: [opus])
        catalog.record(agentID: "claude", models: [])
        #expect(catalog.models(for: "claude") == [opus])
        #expect(ACPAgentModelCatalog(fileURL: file).models(for: "claude") == [opus])
    }

    @Test(arguments: [
        (ChipSpec.Source.configOption(id: "effort"), true),
        (ChipSpec.Source.mode, false),    // pi: thinking is a mode
        (ChipSpec.Source.model, false),   // cursor: thinking is a model-id variant
    ] as [(ChipSpec.Source, Bool)])
    func remembersEffortOnlyWhenItIsAConfigOption(source: ChipSpec.Source, remembered: Bool) {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let high = ChipSpec.Item(id: "high", name: "High", description: nil)

        let first = ACPAgentModelCatalog(fileURL: file)
        first.recordEffort(agentID: "claude", thinking: ChipSpec(source: source, options: [high], currentId: "high"))
        // A later session that reports no thinking control keeps what was remembered.
        first.recordEffort(agentID: "claude", thinking: nil)

        let second = ACPAgentModelCatalog(fileURL: file)
        let expected = ACPAgentModelCatalog.Effort(configId: "effort", levels: [.init(id: "high", name: "High")])
        #expect(second.efforts(for: "claude") == (remembered ? expected : nil))
    }

    @Test func loadsAFileWrittenBeforeEffortsExisted() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(#"{"version":1,"modelsByAgent":{"claude":[{"id":"opus","name":"Opus"}]}}"#.utf8).write(to: file)

        let catalog = ACPAgentModelCatalog(fileURL: file)

        #expect(catalog.models(for: "claude").map(\.id) == ["opus"])
        #expect(catalog.efforts(for: "claude") == nil)
    }
}
