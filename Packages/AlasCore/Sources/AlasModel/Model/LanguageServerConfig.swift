import Foundation
import AlasFoundation

public struct LanguageServerConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String { language }
    public var language: String
    public var extensions: [String]
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var rootMarkers: [String]
    public var gatekeeperHelpers: [String]
    public var gatekeeperRemediationRootMarkers: [String]
    public var enabled: Bool

    public init(
        language: String,
        extensions: [String],
        command: String,
        args: [String],
        env: [String: String],
        rootMarkers: [String],
        gatekeeperHelpers: [String] = [],
        gatekeeperRemediationRootMarkers: [String] = [],
        enabled: Bool
    ) {
        self.language = language
        self.extensions = extensions
        self.command = command
        self.args = args
        self.env = env
        self.rootMarkers = rootMarkers
        self.gatekeeperHelpers = gatekeeperHelpers
        self.gatekeeperRemediationRootMarkers = gatekeeperRemediationRootMarkers
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case language, extensions, command, args, env, rootMarkers, gatekeeperHelpers, gatekeeperRemediationRootMarkers, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        language = try container.decode(String.self, forKey: .language)
        extensions = try container.decode([String].self, forKey: .extensions)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decode([String].self, forKey: .args)
        env = try container.decode([String: String].self, forKey: .env)
        rootMarkers = try container.decode([String].self, forKey: .rootMarkers)
        gatekeeperHelpers = try container.decodeIfPresent([String].self, forKey: .gatekeeperHelpers) ?? []
        gatekeeperRemediationRootMarkers = try container.decodeIfPresent(
            [String].self,
            forKey: .gatekeeperRemediationRootMarkers
        ) ?? []
        enabled = try container.decode(Bool.self, forKey: .enabled)
    }
}
