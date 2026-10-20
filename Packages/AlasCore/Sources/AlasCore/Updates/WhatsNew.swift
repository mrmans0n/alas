import Foundation

extension SemanticVersion: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = SemanticVersion(parsing: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid version \"\(raw)\""))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Actions a "What's new" card can offer. Closed set so bundled JSON cannot
/// reference behavior the app does not implement.
public enum WhatsNewAction: String, Codable, CaseIterable, Sendable {
    case openPluginSettings
}

public struct WhatsNewHeadline: Codable, Equatable, Sendable {
    public let title: String
    public let body: String
    public let media: String?
    public let action: WhatsNewAction?
    public let actionLabel: String?

    public init(
        title: String, body: String, media: String? = nil,
        action: WhatsNewAction? = nil, actionLabel: String? = nil
    ) {
        self.title = title
        self.body = body
        self.media = media
        self.action = action
        self.actionLabel = actionLabel
    }
}

public struct WhatsNewAlso: Codable, Equatable, Sendable {
    public let title: String

    public init(title: String) { self.title = title }
}

public struct WhatsNewEntry: Codable, Equatable, Sendable {
    public let version: SemanticVersion
    public let headline: WhatsNewHeadline
    public let also: [WhatsNewAlso]

    public init(version: SemanticVersion, headline: WhatsNewHeadline, also: [WhatsNewAlso] = []) {
        self.version = version
        self.headline = headline
        self.also = also
    }

    private enum CodingKeys: String, CodingKey { case version, headline, also }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(SemanticVersion.self, forKey: .version)
        headline = try container.decode(WhatsNewHeadline.self, forKey: .headline)
        also = try container.decodeIfPresent([WhatsNewAlso].self, forKey: .also) ?? []
    }

    public var headerTitle: String { "New in \(version.major).\(version.minor)" }

    public var releaseNotesURL: URL {
        URL(string: "https://github.com/mrmans0n/alas/releases/tag/v\(version)")!
    }
}

public struct WhatsNewProblem: Equatable, Sendable {
    public let file: String
    public let message: String

    public init(file: String, message: String) {
        self.file = file
        self.message = message
    }
}

public struct WhatsNewCatalog: Sendable {
    public static let maxAlsoItems = 2

    public let directory: URL
    /// Valid entries only, sorted ascending by version.
    public let entries: [WhatsNewEntry]
    public let problems: [WhatsNewProblem]

    public static func load(directory: URL, fileManager: FileManager = .default) -> WhatsNewCatalog {
        let root = directory.standardizedFileURL
        guard
            let names = try? fileManager.contentsOfDirectory(atPath: directory.path)
        else {
            return WhatsNewCatalog(directory: directory, entries: [], problems: [])
        }

        var entries: [WhatsNewEntry] = []
        var problems: [WhatsNewProblem] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            do {
                let entry = try JSONDecoder().decode(WhatsNewEntry.self, from: Data(contentsOf: url))
                if let message = validate(entry, fileName: name, root: root, fileManager: fileManager) {
                    problems.append(WhatsNewProblem(file: name, message: message))
                } else {
                    entries.append(entry)
                }
            } catch {
                problems.append(WhatsNewProblem(file: name, message: "Could not decode: \(error)"))
            }
        }
        entries.sort { $0.version < $1.version }
        return WhatsNewCatalog(directory: directory, entries: entries, problems: problems)
    }

    /// The media file for an entry, or nil when the entry has none.
    public func mediaURL(for entry: WhatsNewEntry) -> URL? {
        guard let media = entry.headline.media else { return nil }
        return directory.appendingPathComponent(media).standardizedFileURL
    }

    private static func validate(
        _ entry: WhatsNewEntry, fileName: String, root: URL, fileManager: FileManager
    ) -> String? {
        let stem = (fileName as NSString).deletingPathExtension
        guard stem == entry.version.description else {
            return "File name does not match version \(entry.version)"
        }
        guard entry.also.count <= maxAlsoItems else {
            return "At most \(maxAlsoItems) also items are allowed"
        }
        if let media = entry.headline.media {
            guard !media.hasPrefix("/") else { return "Media path must be relative" }
            let resolved = root.appendingPathComponent(media).standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else {
                return "Media path escapes the directory"
            }
            guard fileManager.fileExists(atPath: resolved.path) else {
                return "Media file \(media) does not exist"
            }
        }
        return nil
    }
}
