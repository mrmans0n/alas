import Foundation

struct ProjectsFile: Codable, Equatable {
    var version: Int = 1
    var projects: [ProjectConfig]
}

struct ProjectConfig: Codable, Equatable, Identifiable {
    let id: String           // UUID string
    var name: String         // e.g. nlopez/alas
    var path: String         // absolute repo path
    var color: String        // hex string, e.g. "#5fb7c4"
    var addedAt: Date
    var hiddenWorktreePaths: [String] = []

    enum CodingKeys: String, CodingKey {
        case id, name, path, color, addedAt, hiddenWorktreePaths
    }

    init(
        id: String,
        name: String,
        path: String,
        color: String,
        addedAt: Date,
        hiddenWorktreePaths: [String] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
        self.addedAt = addedAt
        self.hiddenWorktreePaths = hiddenWorktreePaths
    }

    // Tolerant decode: older projects.json files predate hiddenWorktreePaths,
    // so fall back to an empty array. Encode is still synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        color = try c.decode(String.self, forKey: .color)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        hiddenWorktreePaths = (try? c.decode([String].self, forKey: .hiddenWorktreePaths)) ?? []
    }
}
