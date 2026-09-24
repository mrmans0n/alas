import CryptoKit
import Foundation

enum RepoHookTrust {
    private static let version = "alas-repo-hook-trust-v1"

    static func hash(event: RepoHookEvent, bytes: Data) -> String {
        var payload = Data("\(version)\u{0}\(event.rawValue)\u{0}".utf8)
        payload.append(bytes)
        return SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct RepoHookApprovalTarget: Equatable {
    let projectID: String
    let path: URL
    let host: String?

    init(projectID: String, path: URL, host: String?) {
        self.projectID = projectID
        self.path = path.standardizedFileURL
        self.host = host?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PendingRepoHookApprovals {
    private(set) var target: RepoHookApprovalTarget?
    private var hashes = Set<String>()

    mutating func select(_ target: RepoHookApprovalTarget?) {
        guard self.target != target else { return }
        self.target = target
        hashes.removeAll()
    }

    mutating func approve(_ hash: String, for target: RepoHookApprovalTarget) {
        guard self.target == target else { return }
        hashes.insert(hash)
    }

    func contains(_ hash: String, for target: RepoHookApprovalTarget) -> Bool {
        self.target == target && hashes.contains(hash)
    }

    func approvedHashes(for target: RepoHookApprovalTarget?) -> [String] {
        guard let target, self.target == target else { return [] }
        return hashes.sorted()
    }
}
