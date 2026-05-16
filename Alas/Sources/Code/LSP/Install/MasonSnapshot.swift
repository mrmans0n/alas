import Foundation

struct MasonPackage: Codable, Equatable, Sendable, Identifiable {
    let masonId: String
    let displayName: String
    /// Pre-resolved canonical LSP languageId for the primary language. The
    /// generator normalizes Mason's display names (e.g. "Bash" → "shellscript",
    /// "C++" → "cpp") so the Add-language dialog persists a config under the
    /// same languageId the registry uses for the corresponding built-in.
    /// Empty if Mason had no language data; the dialog falls back to masonId.
    let languageId: String
    let languages: [String]
    let extensions: [String]
    let command: String
    let args: [String]
    let recipes: [InstallRecipe]

    var id: String { masonId }
}

struct MasonSnapshot {
    static let maxResults = 25

    let packages: [MasonPackage]

    static let shared: MasonSnapshot = {
        guard let url = Bundle.main.url(forResource: "mason-lsps", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return MasonSnapshot(packages: [])
        }
        struct Envelope: Decodable {
            let packages: [MasonPackage]
        }
        do {
            let env = try JSONDecoder().decode(Envelope.self, from: data)
            return MasonSnapshot(packages: env.packages)
        } catch {
            // Fail open — empty snapshot means the prefill picker shows
            // nothing but the manual form keeps working.
            return MasonSnapshot(packages: [])
        }
    }()

    /// Case-insensitive prefix/contains match across masonId, displayName,
    /// and languages. Empty query returns []. Result count capped at
    /// `maxResults`.
    func search(_ query: String) -> [MasonPackage] {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [MasonPackage] = []
        for pkg in packages {
            let id = pkg.masonId.lowercased()
            let name = pkg.displayName.lowercased()
            if id.contains(q) || name.contains(q) || pkg.languages.contains(where: { $0.lowercased() == q }) {
                out.append(pkg)
                if out.count >= Self.maxResults { break }
            }
        }
        return out
    }
}
