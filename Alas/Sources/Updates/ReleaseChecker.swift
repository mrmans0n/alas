import Foundation

/// Queries GitHub for the latest stable release and produces a verdict.
/// Network access is injected via `fetch` so tests run offline.
struct ReleaseChecker {
    enum CheckResult: Equatable {
        case upToDate
        case updateAvailable(ReleaseInfo)
        case failed(String)
    }

    typealias Fetch = (URL) async throws -> Data

    let latestReleaseURL: URL
    let arch: String
    let fetch: Fetch

    init(
        latestReleaseURL: URL = URL(string: "https://api.github.com/repos/mrmans0n/alas/releases/latest")!,
        arch: String = HostArch.assetSlug,
        fetch: @escaping Fetch = ReleaseChecker.defaultFetch
    ) {
        self.latestReleaseURL = latestReleaseURL
        self.arch = arch
        self.fetch = fetch
    }

    func check(current: SemanticVersion) async -> CheckResult {
        do {
            let data = try await fetch(latestReleaseURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(GitHubRelease.self, from: data)
            guard let info = ReleaseInfo.make(from: release, arch: arch) else {
                return .failed("The latest release could not be read.")
            }
            return info.version > current ? .updateAvailable(info) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func defaultFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Alas", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
