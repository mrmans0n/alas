import Foundation

struct ProjectAvatarPreset: Equatable {
    let label: String
    let url: URL
}

protocol ProjectAvatarFetching {
    func data(from url: URL) async throws -> Data
}

struct URLSessionProjectAvatarFetcher: ProjectAvatarFetching {
    func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

enum ProjectAvatarPresetProvider {
    static func candidate(for remote: CodeHostRemote) -> ProjectAvatarPreset? {
        switch remote.kind {
        case .github:
            guard let url = URL(string: "https://\(remote.host)/\(remote.owner).png?size=256") else {
                return nil
            }
            return ProjectAvatarPreset(label: "GitHub avatar: \(remote.owner)", url: url)
        case .gitlab:
            let escaped = remote.owner.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
                .replacingOccurrences(of: "/", with: "%2F")
            guard let escaped,
                  let url = URL(string: "https://\(remote.host)/api/v4/groups/\(escaped)/avatar")
            else {
                return nil
            }
            return ProjectAvatarPreset(label: "GitLab avatar: \(remote.owner)", url: url)
        }
    }

    static func candidate(from remotes: [GitRemote]) -> ProjectAvatarPreset? {
        guard let remote = CodeHostRemoteDetector.detect(from: remotes) else { return nil }
        return candidate(for: remote)
    }

    static func fetch(
        _ preset: ProjectAvatarPreset,
        fetcher: ProjectAvatarFetching = URLSessionProjectAvatarFetcher()
    ) async throws -> Data {
        try await fetcher.data(from: preset.url)
    }
}
