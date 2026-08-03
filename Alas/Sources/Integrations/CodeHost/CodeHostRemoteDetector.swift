import Foundation

struct GitRemote: Equatable, Sendable {
    enum Direction: Equatable, Sendable {
        case fetch
        case push
    }

    let name: String
    let url: String
    let direction: Direction

    init(name: String, url: String, direction: Direction = .fetch) {
        self.name = name
        self.url = url
        self.direction = direction
    }
}

enum CodeHostRemoteDetector {
    static func preferredRemoteName(forBaseBranch baseBranch: String, remotes: [GitRemote]) -> String? {
        remotes.first { baseBranch.hasPrefix("\($0.name)/") }?.name
    }

    static func detect(
        from remotes: [GitRemote],
        supportedKinds: Set<CodeHostKind>? = nil,
        preferredRemoteName: String? = nil
    ) -> CodeHostRemote? {
        detectAll(
            from: remotes,
            supportedKinds: supportedKinds,
            preferredRemoteName: preferredRemoteName
        ).first
    }

    static func detect(from remotes: [GitRemote], matching kind: CodeHostKind) -> CodeHostRemote? {
        remotes
            .filter { $0.direction == .fetch }
            .sorted { lhs, rhs in
                let lhsPriority = priority(for: lhs.name, preferredRemoteName: nil)
                let rhsPriority = priority(for: rhs.name, preferredRemoteName: nil)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.name < rhs.name
            }
            .compactMap { parse(remote: $0, supportedKinds: nil, kindOverride: kind) }
            .first
    }

    static func detectAll(
        from remotes: [GitRemote],
        supportedKinds: Set<CodeHostKind>? = nil,
        preferredRemoteName: String? = nil
    ) -> [CodeHostRemote] {
        remotes
            .filter { $0.direction == .fetch }
            .sorted { lhs, rhs in
                let lhsPriority = priority(for: lhs.name, preferredRemoteName: preferredRemoteName)
                let rhsPriority = priority(for: rhs.name, preferredRemoteName: preferredRemoteName)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.name < rhs.name
            }
            .compactMap { parse(remote: $0, supportedKinds: supportedKinds, kindOverride: nil) }
    }

    private static func priority(for remoteName: String, preferredRemoteName: String?) -> Int {
        if let preferredRemoteName, remoteName == preferredRemoteName { return 0 }
        if remoteName == "origin" { return 1 }
        return 2
    }

    private static func parse(
        remote: GitRemote,
        supportedKinds: Set<CodeHostKind>?,
        kindOverride: CodeHostKind?
    ) -> CodeHostRemote? {
        guard let components = parseComponents(from: remote.url),
              let kind = kindOverride ?? kind(for: components.host)
        else {
            return nil
        }
        if let supportedKinds, !supportedKinds.contains(kind) {
            return nil
        }

        let pathParts = components.pathParts
        guard pathParts.count >= 2 else { return nil }

        let repository = stripGitSuffix(from: pathParts.last ?? "")
        let ownerParts = pathParts.dropLast()
        let owner = ownerParts.joined(separator: "/")
        guard !owner.isEmpty, !repository.isEmpty else { return nil }

        guard let webURL = URL(string: "https://\(components.host)/\(owner)/\(repository)") else {
            return nil
        }

        return CodeHostRemote(
            kind: kind,
            host: components.host,
            owner: owner,
            repository: repository,
            remoteName: remote.name,
            webURL: webURL
        )
    }

    private static func parseComponents(from remoteURL: String) -> RemoteComponents? {
        if let url = URLComponents(string: remoteURL),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ssh"].contains(scheme),
           let host = url.host?.lowercased()
        {
            return RemoteComponents(host: host, pathParts: splitPath(url.path))
        }

        let parts = remoteURL.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let hostPrefix = parts[0]
        let host: String
        if let atIndex = hostPrefix.lastIndex(of: "@") {
            guard atIndex < hostPrefix.index(before: hostPrefix.endIndex) else { return nil }
            let hostStart = hostPrefix.index(after: atIndex)
            host = String(hostPrefix[hostStart...]).lowercased()
        } else {
            host = String(hostPrefix).lowercased()
        }
        guard !host.isEmpty else { return nil }

        return RemoteComponents(host: host, pathParts: splitPath(String(parts[1])))
    }

    private static func splitPath(_ path: String) -> [String] {
        path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func kind(for host: String) -> CodeHostKind? {
        if host == "github.com" {
            return .github
        }

        if host == "gitlab.com" || host.split(separator: ".").first == "gitlab" {
            return .gitlab
        }

        return nil
    }

    private static func stripGitSuffix(from repository: String) -> String {
        guard repository.hasSuffix(".git") else { return repository }
        return String(repository.dropLast(4))
    }

    private struct RemoteComponents {
        let host: String
        let pathParts: [String]
    }
}
