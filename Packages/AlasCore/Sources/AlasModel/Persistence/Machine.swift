import Foundation
import AlasFoundation

/// A user-managed SSH execution location offered when creating worktrees.
public struct Machine: Codable, Equatable, Identifiable, Sendable {
    /// SSH destination exactly as passed to ssh: an alias or `user@host`.
    /// It is the host embedded in every `RemotePath`, so it never changes.
    public let destination: String
    public var label: String
    /// Path on the machine where clones go, e.g. `~/code`.
    public var projectsFolder: String

    public var id: String { destination }

    public init(destination: String, label: String? = nil, projectsFolder: String) {
        self.destination = destination
        self.label = label ?? destination
        self.projectsFolder = projectsFolder
    }

    private enum CodingKeys: String, CodingKey { case destination, label, projectsFolder }

    /// Only the destination is required; a hand-edited or older entry keeps
    /// what it has and takes defaults for the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let destination = try c.decode(String.self, forKey: .destination)
        self.init(
            destination: destination,
            label: try? c.decode(String.self, forKey: .label),
            projectsFolder: (try? c.decode(String.self, forKey: .projectsFolder)) ?? "~/code"
        )
    }

    /// Decodes a list entry by entry, dropping only the entries that cannot
    /// name a destination.
    public static func decodeList(from decoder: Decoder) throws -> [Machine] {
        var list = try decoder.unkeyedContainer()
        var machines: [Machine] = []
        while !list.isAtEnd {
            if let machine = try? list.decode(Machine.self) {
                machines.append(machine)
            } else {
                _ = try? list.decode(Discarded.self)
            }
        }
        return machines
    }

    private struct Discarded: Decodable {}

    /// The local clone root mirrored under the machine's home, or `~/code`
    /// when it is unset or outside the local home.
    public static func defaultProjectsFolder(cloneRoot: String, localHome: String = NSHomeDirectory()) -> String {
        let home = URL(fileURLWithPath: localHome).standardizedFileURL.pathComponents
        let root = URL(fileURLWithPath: cloneRoot).standardizedFileURL.pathComponents
        guard !cloneRoot.isEmpty, root.count > home.count, Array(root.prefix(home.count)) == home else {
            return "~/code"
        }
        return "~/" + root.dropFirst(home.count).joined(separator: "/")
    }

    /// `machines` plus one entry per routable project host not yet listed,
    /// in first-seen order. Existing entries are kept unchanged.
    public static func seeded(_ machines: [Machine], projectHosts: [String], defaultProjectsFolder: String) -> [Machine] {
        var result = machines
        var known = Set(machines.map(\.destination))
        for host in projectHosts
        where host != RemotePath.unavailableHost && RemotePath.isValidHost(host) && known.insert(host).inserted {
            result.append(Machine(destination: host, projectsFolder: defaultProjectsFolder))
        }
        return result
    }
}
