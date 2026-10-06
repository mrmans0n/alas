import Foundation
import Observation
import SwiftUI

/// The servers one diff or review pane keeps alive, as toolbar chips.
@MainActor
@Observable
final class LSPServerLeaseSet {
    struct Input: Hashable, Sendable {
        let worktreeRoot: URL
        let relativePath: String
        let language: String
    }

    private(set) var chips: [LSPServerChipModel] = []
    @ObservationIgnored private var leases: [UUID: LSPServerLease] = [:]

    /// Files that exist in the working tree and map to a configured language,
    /// enabled or not. Matches the existing diff LSP gate.
    static func inputs(worktreeRoot: URL, relativePaths: [String], registry: LanguageServerRegistry) -> [Input] {
        relativePaths.compactMap { path in
            guard let language = registry.configuredLanguage(forPath: path) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: worktreeRoot.appendingPathComponent(path).path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else { return nil }
            return Input(worktreeRoot: worktreeRoot, relativePath: path, language: language)
        }
    }

    /// Retains one server per (root, language, directory) group, then drops the
    /// previous leases. Directories bound remote root probes; duplicates that
    /// resolve to the same server are released at once.
    func update(inputs: [Input], manager: WorkspaceLSPManager) async {
        struct Group: Hashable {
            let worktreeRoot: URL
            let language: String
            let directory: String
        }
        let groups = Dictionary(grouping: inputs) {
            Group(worktreeRoot: $0.worktreeRoot, language: $0.language, directory: ($0.relativePath as NSString).deletingLastPathComponent)
        }
        var acquired: [UUID: LSPServerLease] = [:]
        var unavailable: [LSPServerChipModel] = []
        for files in groups.values {
            guard let file = files.first else { continue }
            if Task.isCancelled { break }
            let result = await manager.retainServer(
                worktreeRoot: file.worktreeRoot,
                fileURL: file.worktreeRoot.appendingPathComponent(file.relativePath),
                languageId: file.language
            )
            switch result {
            case .serving(let lease):
                if acquired[lease.status.id] == nil { acquired[lease.status.id] = lease } else { lease.release() }
            case .unavailable(let language, let reason):
                unavailable.append(.unavailable(language: language, reason: reason))
            }
        }
        guard !Task.isCancelled else {
            acquired.values.forEach { $0.release() }
            return
        }
        let previous = leases
        leases = acquired
        previous.values.forEach { $0.release() }
        let models = acquired.values.map { LSPServerChipModel.serving($0.status) } + unavailable
        let order = LSPServerChipAggregation.ordered(models.map(\.snapshot)).map(\.id)
        chips = order.compactMap { id in models.first { $0.id == id } }
    }

    func release() {
        leases.values.forEach { $0.release() }
        leases.removeAll()
        chips = []
    }
}

private struct LSPServerLeasesModifier: ViewModifier {
    struct TaskKey: Hashable {
        let inputs: [LSPServerLeaseSet.Input]
        let registryGeneration: Int
    }

    let leaseSet: LSPServerLeaseSet
    let inputs: [LSPServerLeaseSet.Input]
    let manager: WorkspaceLSPManager?

    func body(content: Content) -> some View {
        content
            .task(id: TaskKey(inputs: inputs, registryGeneration: manager?.registryGeneration ?? 0)) {
                guard let manager else { return }
                await leaseSet.update(inputs: inputs, manager: manager)
            }
            .onDisappear { leaseSet.release() }
    }
}

extension View {
    /// Keeps the servers for `inputs` running while this view is on screen.
    func lspServerLeases(_ leaseSet: LSPServerLeaseSet, inputs: [LSPServerLeaseSet.Input], manager: WorkspaceLSPManager?) -> some View {
        modifier(LSPServerLeasesModifier(leaseSet: leaseSet, inputs: inputs, manager: manager))
    }
}
