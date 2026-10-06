import Foundation

/// Fetches the official ACP agent registry. Network access is injected via
/// `fetch` so tests run offline.
struct ACPRegistryClient: Sendable {
    typealias Fetch = @Sendable (URL) async throws -> Data

    static let indexURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!

    let indexURL: URL
    let fetch: Fetch

    init(
        indexURL: URL = ACPRegistryClient.indexURL,
        fetch: @escaping Fetch = { try await ACPRegistryClient.defaultFetch($0) }
    ) {
        self.indexURL = indexURL
        self.fetch = fetch
    }

    /// Registry agents sorted by display name.
    func agents() async throws -> [ACPRegistryAgent] {
        let index = try JSONDecoder().decode(ACPRegistryIndex.self, from: try await fetch(indexURL))
        return index.agents.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func defaultFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Alas", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
