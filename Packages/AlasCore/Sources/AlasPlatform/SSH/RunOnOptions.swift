import Foundation
import AlasModel

/// One row of New Worktree's Run on picker.
public struct RunOnOption: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case thisMac
        /// The project already has a linked checkout on the machine.
        case ready(projectId: String, reachability: RemoteHostReachability)
        /// A Machine with no checkout of the project yet.
        case needsSetup
    }

    /// The Machine's destination; nil for this Mac.
    public let host: String?
    public let label: String
    public let detail: String
    public let kind: Kind
    /// Why the row can't be chosen; nil when it can.
    public let disabledReason: String?

    public var id: String { host ?? "" }

    public init(host: String?, label: String, detail: String, kind: Kind, disabledReason: String?) {
        self.host = host
        self.label = label
        self.detail = detail
        self.kind = kind
        self.disabledReason = disabledReason
    }
}

public enum RunOnOptions {
    public static let noOriginReason = "No git remote: only this Mac can run it"

    /// This Mac, then machines with a linked checkout (in Machines order, then
    /// unlisted hosts by name), then listed machines that need setup. Only
    /// This Mac can run a primary whose origin does not normalize.
    public static func make(
        primary: ProjectConfig,
        hasOrigin: Bool,
        linked: [ProjectConfig],
        machines: [Machine],
        reachability: (String) -> RemoteHostReachability
    ) -> [RunOnOption] {
        let order = Dictionary(uniqueKeysWithValues: machines.enumerated().map { ($0.element.destination, $0.offset) })
        let ready = linked.compactMap { record in record.host.map { (host: $0, record: record) } }
            .sorted { (order[$0.host] ?? .max, $0.host) < (order[$1.host] ?? .max, $1.host) }
            .map { host, record in
                RunOnOption(
                    host: host,
                    label: machines.first { $0.destination == host }?.label ?? host,
                    detail: RemotePath.display(record.path),
                    kind: .ready(projectId: record.id, reachability: reachability(host)),
                    disabledReason: hasOrigin ? nil : noOriginReason
                )
            }
        let readyHosts = Set(ready.compactMap(\.host))
        let needsSetup = machines.filter { !readyHosts.contains($0.destination) }.map {
            RunOnOption(
                host: $0.destination,
                label: $0.label,
                detail: "Will set up in \($0.projectsFolder)",
                kind: .needsSetup,
                disabledReason: hasOrigin ? nil : noOriginReason
            )
        }
        let thisMac = RunOnOption(host: nil, label: "This Mac", detail: primary.path, kind: .thisMac, disabledReason: nil)
        return [thisMac] + ready + needsSetup
    }

    /// The last machine used, while it can still run the project; else This Mac.
    public static func preselectedHost(in options: [RunOnOption], lastRunOnHost: String?) -> String? {
        options.first { $0.host == lastRunOnHost && $0.disabledReason == nil }?.host
    }
}
