import Foundation
import os

private let catalogLogger = Logger(subsystem: "io.nlopez.alas", category: "ACPAgentModelCatalog")

/// The models each ACP agent has advertised, remembered across sessions.
///
/// An agent only names its models in the `session/new` response, so a surface
/// that configures a session before it exists — a schedule that will open one
/// at 3am — has nothing to offer until some session with that agent has been
/// opened. This keeps the last list each agent reported so such a surface can
/// pick from it. The list is a hint, not a contract: the agent is still the
/// authority when the session starts, and an id it no longer knows is
/// refused there.
@MainActor
@Observable
final class ACPAgentModelCatalog {
    struct Model: Codable, Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    private(set) var modelsByAgent: [String: [Model]] = [:]

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let fileURL: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), fileURL: URL = Paths.acpModelCatalogFile) {
        self.store = store
        self.fileURL = fileURL
        do {
            modelsByAgent = try store.readIfExists(File.self, from: fileURL)?.modelsByAgent ?? [:]
        } catch {
            catalogLogger.error("Could not load the model catalog: \(String(describing: error), privacy: .public)")
        }
    }

    func models(for agentID: String) -> [Model] {
        modelsByAgent[agentID] ?? []
    }

    /// Replaces what is remembered for `agentID` with the list it just
    /// advertised. An empty list is ignored: an agent that reports no models
    /// on one connection (a failed provider lookup, say) should not erase a
    /// list it reported before.
    func record(agentID: String, models: [Model]) {
        guard !models.isEmpty, modelsByAgent[agentID] != models else { return }
        modelsByAgent[agentID] = models
        do {
            try store.write(File(modelsByAgent: modelsByAgent), to: fileURL)
        } catch {
            catalogLogger.error("Could not save the model catalog: \(String(describing: error), privacy: .public)")
        }
    }

    private struct File: Codable {
        var version = 1
        var modelsByAgent: [String: [Model]]
    }
}

extension Paths {
    static var acpModelCatalogFile: URL {
        appSupportRoot.appendingPathComponent("acp-model-catalog.json")
    }
}
