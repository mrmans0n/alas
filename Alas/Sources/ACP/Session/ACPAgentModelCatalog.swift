import Foundation
import os

private let catalogLogger = Logger(subsystem: "io.nlopez.alas", category: "ACPAgentModelCatalog")

/// The models and thinking levels each ACP agent has advertised, remembered
/// across sessions.
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

    struct EffortLevel: Codable, Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String
    }

    /// An agent's thinking levels and the config option that sets them.
    struct Effort: Codable, Equatable, Sendable {
        let configId: String
        let levels: [EffortLevel]
    }

    /// What a live session of an agent reported during this app run. The
    /// persisted list survives relaunches, so on its own it cannot tell a
    /// list the agent confirmed today from one it named weeks ago.
    enum LaunchReport: Equatable, Sendable {
        case notObserved
        case advertisedModels
        case advertisedNone
    }

    private(set) var modelsByAgent: [String: [Model]] = [:]
    private(set) var effortsByAgent: [String: Effort] = [:]
    @ObservationIgnored private var launchReports: [String: LaunchReport] = [:]
    /// What each agent advertised on each execution host during this launch
    /// (nil host = this Mac). Hosts can run different adapter versions, so a
    /// list confirmed on one never vouches for another.
    @ObservationIgnored private var launchModelsByHost: [HostKey: [Model]] = [:]
    private struct HostKey: Hashable {
        let agentID: String
        let host: String?
    }

    @ObservationIgnored private let store: any PersistenceStoreProtocol
    @ObservationIgnored private let fileURL: URL

    init(store: any PersistenceStoreProtocol = PersistenceStore(), fileURL: URL = Paths.acpModelCatalogFile) {
        self.store = store
        self.fileURL = fileURL
        do {
            let file = try store.readIfExists(File.self, from: fileURL)
            modelsByAgent = file?.modelsByAgent ?? [:]
            effortsByAgent = file?.effortsByAgent ?? [:]
        } catch {
            catalogLogger.error("Could not load the model catalog: \(String(describing: error), privacy: .public)")
        }
    }

    func models(for agentID: String) -> [Model] {
        modelsByAgent[agentID] ?? []
    }

    func launchReport(for agentID: String) -> LaunchReport {
        launchReports[agentID] ?? .notObserved
    }

    /// The models `agentID` advertised on `host` during this launch: nil when
    /// no live session there has reported, empty when one advertised none.
    func launchModels(for agentID: String, host: String?) -> [Model]? {
        launchModelsByHost[HostKey(agentID: agentID, host: host)]
    }

    func efforts(for agentID: String) -> Effort? {
        effortsByAgent[agentID]
    }

    /// Remembers the thinking levels `agentID` advertised as a select config
    /// option, the only form a peer can set before a session exists. Thinking
    /// advertised as a mode (pi) or as model-id variants (Cursor) is not
    /// remembered, and a session that reports no levels never erases them.
    func recordEffort(agentID: String, thinking: ChipSpec?) {
        guard let thinking, case .configOption(let configId) = thinking.source,
              !thinking.options.isEmpty else { return }
        let effort = Effort(
            configId: configId,
            levels: thinking.options.map { EffortLevel(id: $0.id, name: $0.name) }
        )
        guard effortsByAgent[agentID] != effort else { return }
        effortsByAgent[agentID] = effort
        save()
    }

    /// Replaces what is remembered for `agentID` with the list it just
    /// advertised. An empty list is ignored: an agent that reports no models
    /// on one connection (a failed provider lookup, say) should not erase a
    /// list it reported before.
    func record(agentID: String, models: [Model], host: String? = nil) {
        let key = HostKey(agentID: agentID, host: host)
        if !models.isEmpty || launchModelsByHost[key]?.isEmpty != false {
            launchModelsByHost[key] = models
        }
        guard !models.isEmpty else {
            if launchReports[agentID] != .advertisedModels {
                launchReports[agentID] = .advertisedNone
            }
            return
        }
        launchReports[agentID] = .advertisedModels
        guard modelsByAgent[agentID] != models else { return }
        modelsByAgent[agentID] = models
        save()
    }

    private func save() {
        do {
            try store.write(File(modelsByAgent: modelsByAgent, effortsByAgent: effortsByAgent), to: fileURL)
        } catch {
            catalogLogger.error("Could not save the model catalog: \(String(describing: error), privacy: .public)")
        }
    }

    private struct File: Codable {
        var version = 1
        var modelsByAgent: [String: [Model]]
        /// Absent in files written before efforts were remembered.
        var effortsByAgent: [String: Effort]?
    }
}

extension Paths {
    static var acpModelCatalogFile: URL {
        appSupportRoot.appendingPathComponent("acp-model-catalog.json")
    }
}
