import Foundation

struct WorkspaceStateFile: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var workspaces: [Workspace]
    var checkouts: [WorkspaceCheckout]
    var spaceLayouts: [WorkspaceSpaceLayout]

    init(
        version: Int = WorkspaceStateFile.currentVersion,
        workspaces: [Workspace] = [],
        checkouts: [WorkspaceCheckout] = [],
        spaceLayouts: [WorkspaceSpaceLayout] = []
    ) {
        self.version = version
        self.workspaces = workspaces
        self.checkouts = checkouts
        self.spaceLayouts = spaceLayouts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        checkouts = try container.decodeIfPresent([WorkspaceCheckout].self, forKey: .checkouts) ?? []
        spaceLayouts = try container.decodeIfPresent([WorkspaceSpaceLayout].self, forKey: .spaceLayouts) ?? []
    }

    func validated() throws -> WorkspaceStateFile {
        guard version == Self.currentVersion else {
            throw WorkspaceStateFileError.unsupportedVersion(version)
        }
        try validateUniqueIDs()
        return self
    }

    private func validateUniqueIDs() throws {
        guard Set(workspaces.map(\.id)).count == workspaces.count else {
            throw WorkspaceStateFileError.duplicateIdentity("workspace")
        }
        for workspace in workspaces {
            guard Set(workspace.members.map(\.id)).count == workspace.members.count else {
                throw WorkspaceStateFileError.duplicateIdentity("workspaceMember")
            }
        }
        guard Set(checkouts.map(\.id)).count == checkouts.count else {
            throw WorkspaceStateFileError.duplicateIdentity("checkout")
        }
        for checkout in checkouts {
            guard Set(checkout.members.map(\.id)).count == checkout.members.count else {
                throw WorkspaceStateFileError.duplicateIdentity("checkoutMember")
            }
        }
        guard Set(spaceLayouts.map(\.spaceID)).count == spaceLayouts.count else {
            throw WorkspaceStateFileError.duplicateIdentity("spaceLayout")
        }
    }

    mutating func reconcileSpaceLayouts(with spacesFile: SpacesFile) -> SpacesFile {
        let result = WorkspaceSpaceMigration.reupgrade(
            spacesFile: spacesFile,
            savedLayouts: spaceLayouts
        )
        spaceLayouts = result.layouts
        var reconciled = spacesFile
        reconciled.spaces = result.spaces
        return reconciled
    }

    mutating func checkpointSpaceLayouts(from spacesFile: SpacesFile) {
        spaceLayouts = WorkspaceSpaceMigration.layouts(for: spacesFile.spaces)
    }
}

enum WorkspaceStateFileError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case duplicateIdentity(String)
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
