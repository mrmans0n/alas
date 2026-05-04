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
}
