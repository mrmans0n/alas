import CryptoKit
import Foundation
import AlasFoundation
import AlasModel

public enum RepoHookTrust: Sendable {
    private static let version = "alas-repo-hook-trust-v1"

    public static func hash(event: RepoHookEvent, bytes: Data) -> String {
        var payload = Data("\(version)\u{0}\(event.rawValue)\u{0}".utf8)
        payload.append(bytes)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct RepoHookApprovalTarget: Equatable, Sendable {
    public let projectID: String
    public let path: URL
    public let host: String?

    public init(projectID: String, path: URL, host: String?) {
        self.projectID = projectID
        self.path = path.standardizedFileURL
        self.host = host?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct PendingRepoHookApprovals: Sendable {
    public private(set) var target: RepoHookApprovalTarget?
    private var hashes = Set<String>()

    public init() {}

    public mutating func select(_ target: RepoHookApprovalTarget?) {
        guard self.target != target else { return }
        self.target = target
        hashes.removeAll()
    }

    public mutating func approve(_ hash: String, for target: RepoHookApprovalTarget) {
        guard self.target == target else { return }
        hashes.insert(hash)
    }

    public func contains(_ hash: String, for target: RepoHookApprovalTarget) -> Bool {
        self.target == target && hashes.contains(hash)
    }

    public func approvedHashes(for target: RepoHookApprovalTarget?) -> [String] {
        guard let target, self.target == target else { return [] }
        return hashes.sorted()
    }
}
