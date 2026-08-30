import Foundation

struct WorkspaceStateFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var workspaces: [Workspace]
    var checkouts: [WorkspaceCheckout]

    init(
        version: Int = WorkspaceStateFile.currentVersion,
        workspaces: [Workspace] = [],
        checkouts: [WorkspaceCheckout] = []
    ) {
        self.version = version
        self.workspaces = workspaces
        self.checkouts = checkouts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        checkouts = try container.decodeIfPresent([WorkspaceCheckout].self, forKey: .checkouts) ?? []
    }

    func validated() throws -> WorkspaceStateFile {
        guard version == Self.currentVersion else {
            throw WorkspaceStateFileError.unsupportedVersion(version)
        }
        return self
    }
}

enum WorkspaceStateFileError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
}

extension JSONEncoder {
    static var workspace: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var workspace: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
