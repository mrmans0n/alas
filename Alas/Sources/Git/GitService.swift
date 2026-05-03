import Foundation

struct GitService {
    func isGitRepository(_ path: URL) async throws -> Bool {
        let result = try await Process.git(["rev-parse", "--is-inside-work-tree"], cwd: path)
        return result.exitCode == 0 &&
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Parses `<owner>/<repo>` from `origin` remote URL, falls back to folder name.
    func suggestProjectName(_ path: URL) async throws -> String {
        let result = try await Process.git(["remote", "get-url", "origin"], cwd: path)
        guard result.exitCode == 0 else { return path.lastPathComponent }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.parseRemote(url) ?? path.lastPathComponent
    }

    static func parseRemote(_ url: String) -> String? {
        // https://host/owner/repo(.git)?  or  git@host:owner/repo(.git)?
        var trimmed = url
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        if trimmed.contains("://") {
            // https://github.com/owner/repo
            let parts = trimmed.split(separator: "/")
            guard parts.count >= 2 else { return nil }
            return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
        }
        if trimmed.contains("@") && trimmed.contains(":") {
            // git@github.com:owner/repo
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let pathPart = parts[1]
            let segs = pathPart.split(separator: "/")
            guard segs.count >= 2 else { return nil }
            return "\(segs[segs.count - 2])/\(segs[segs.count - 1])"
        }
        return nil
    }
}
