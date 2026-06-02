import Foundation

/// Queries GitHub for the release on the build's track and produces a verdict.
/// Network access is injected via `fetch` so tests run offline.
struct ReleaseChecker {
    enum CheckResult: Equatable {
        case upToDate
        case updateAvailable(ReleaseInfo)
        case failed(String)
    }

    typealias Fetch = (URL) async throws -> Data

    let stableReleaseURL: URL
    let nightlyReleaseURL: URL
    let arch: String
    let fetch: Fetch

    init(
        stableReleaseURL: URL = URL(string: "https://api.github.com/repos/mrmans0n/alas/releases/latest")!,
        nightlyReleaseURL: URL = URL(string: "https://api.github.com/repos/mrmans0n/alas/releases/tags/nightly")!,
        arch: String = HostArch.assetSlug,
        fetch: @escaping Fetch = ReleaseChecker.defaultFetch
    ) {
        self.stableReleaseURL = stableReleaseURL
        self.nightlyReleaseURL = nightlyReleaseURL
        self.arch = arch
        self.fetch = fetch
    }

    func check(identity: BuildIdentity) async -> CheckResult {
        switch identity.track {
        case .stable:
            return await checkStable(identity: identity)
        case .nightly:
            return await checkNightly(identity: identity)
        }
    }

    private func checkStable(identity: BuildIdentity) async -> CheckResult {
        do {
            let release = try await fetchRelease(at: stableReleaseURL)
            guard let info = ReleaseInfo.makeStable(from: release, arch: arch) else {
                return .failed("The latest release could not be read.")
            }
            guard case let .stable(stable) = info else {
                return .failed("The latest release could not be read.")
            }
            return stable.version > identity.version ? .updateAvailable(info) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func checkNightly(identity: BuildIdentity) async -> CheckResult {
        do {
            let release = try await fetchRelease(at: nightlyReleaseURL)
            guard let info = ReleaseInfo.makeNightly(from: release) else {
                return .failed("The latest nightly could not be read.")
            }
            guard case let .nightly(nightly) = info else {
                return .failed("The latest nightly could not be read.")
            }

            // SHA + publishedAt pairing: a re-tag to the same SHA must not
            // look like an update, and a force-pushed older SHA must not.
            if let localSHA = identity.gitSHA {
                let shaChanged = nightly.fullSHA != localSHA
                let publishedNewer = identity.buildDate.map { nightly.publishedAt > $0 } ?? true
                return (shaChanged && publishedNewer) ? .updateAvailable(info) : .upToDate
            } else {
                // No local SHA stamped — fall back to date-only compare.
                let publishedNewer = identity.buildDate.map { nightly.publishedAt > $0 } ?? true
                return publishedNewer ? .updateAvailable(info) : .upToDate
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func fetchRelease(at url: URL) async throws -> GitHubRelease {
        let data = try await fetch(url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
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
