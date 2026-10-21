import Foundation
import AlasFoundation

public struct ACPCodexHooksDeclaration: Codable, Equatable, Sendable {
    public let version: Int
    public init() { version = 1 }
}

public struct ACPCodexHooksCapability: Codable, Equatable, Sendable {
    public let version: Int
    public let reviewToken: Bool
    public var isSupported: Bool { version == 1 && reviewToken }

    /// The prerelease revision is part of this protocol's verified release floor.
    public static func supports(agentInfo: ACPImplementationInfo?) -> Bool {
        guard let agentInfo, agentInfo.name == "@alas-ide/codex-acp" else { return false }
        let parts = agentInfo.version.components(separatedBy: "-alas.")
        guard parts.count == 2, let revision = Int(parts[1]), revision > 0,
              String(revision) == parts[1] else { return false }
        let base = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard base.count == 3 else { return false }
        let numbers = base.compactMap { Int($0) }
        guard numbers.count == 3, numbers.allSatisfy({ $0 >= 0 }) else { return false }
        if numbers[0] != 2 { return numbers[0] > 2 }
        if numbers[1] != 2 { return numbers[1] > 2 }
        if numbers[2] != 2 { return numbers[2] > 2 }
        return revision >= 4
    }
}

public struct ACPCodexHookReviewMetadata: Codable, Equatable, Sendable {
    public let reviewToken: String
    public init(reviewToken: String) { self.reviewToken = reviewToken }
}

public struct ACPCodexHookIdentity: Codable, Hashable, Sendable {
    public let key: String
    public let currentHash: String
    public init(key: String, currentHash: String) { self.key = key; self.currentHash = currentHash }
}

/// Raw strings preserve future adapter values for inspection, while eligibility fails closed.
public struct ACPCodexHook: Decodable, Equatable, Sendable {
    public let key: String
    public let currentHash: String
    public let eventName: String
    public let matcher: String?
    public let timeoutSec: Int64
    public let statusMessage: String?
    public let additionalContextLimit: Int?
    public let sourcePath: String
    public let source: String
    public let pluginId: String?
    public let displayOrder: Int64
    public let enabled: Bool
    public let isManaged: Bool
    public let trustStatus: String
    public let handlerType: String
    public let command: String?
    public let server: String?
    public let tool: String?
    public let async: Bool?

    public var identity: ACPCodexHookIdentity { .init(key: key, currentHash: currentHash) }
    public var isKnown: Bool {
        let events = ["preToolUse", "permissionRequest", "postToolUse", "preCompact", "postCompact", "sessionStart", "sessionEnd", "userPromptSubmit", "subagentStart", "subagentStop", "stop", "interrupt"]
        guard !key.isEmpty, !currentHash.isEmpty, !sourcePath.isEmpty,
              source == "sessionFlags", events.contains(eventName),
              ["managed", "trusted", "untrusted", "modified"].contains(trustStatus) else { return false }
        switch handlerType {
        case "command": return command?.isEmpty == false && async != nil
        case "mcpTool": return server?.isEmpty == false && tool?.isEmpty == false
        case "prompt", "agent": return true
        default: return false
        }
    }
    public var canTrust: Bool { isKnown && !isManaged && ["untrusted", "modified"].contains(trustStatus) }
}

public struct ACPCodexHooksList: Decodable, Equatable, Sendable {
    public struct Diagnostic: Decodable, Equatable, Sendable {
        public let path: String
        public let message: String
    }
    public let cwd: String
    public let hooks: [ACPCodexHook]
    public let warnings: [String]
    public let errors: [Diagnostic]
    public let reviewToken: String
    public let codexHome: String?

    private enum CodingKeys: String, CodingKey { case cwd, hooks, warnings, errors, reviewToken, codexHome }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try c.decode(String.self, forKey: .cwd)
        hooks = try c.decode([ACPCodexHook].self, forKey: .hooks)
        warnings = try c.decode([String].self, forKey: .warnings)
        errors = try c.decode([Diagnostic].self, forKey: .errors)
        reviewToken = try c.decode(String.self, forKey: .reviewToken)
        codexHome = try c.decodeIfPresent(String.self, forKey: .codexHome)
        guard !cwd.isEmpty, !reviewToken.isEmpty, hooks.allSatisfy({ !$0.key.isEmpty && !$0.currentHash.isEmpty }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Hook review is missing a required identity or token"))
        }
    }
    public func isUnique(_ identity: ACPCodexHookIdentity) -> Bool {
        hooks.filter { $0.key == identity.key }.count == 1 && hooks.contains { $0.identity == identity }
    }
    public var requiresReview: Bool {
        !warnings.isEmpty || !errors.isEmpty || hooks.contains {
            !$0.isKnown || !isUnique($0.identity) || !["trusted", "managed"].contains($0.trustStatus)
        }
    }
}

public enum ACPCodexHookReviewError: String, Sendable {
    case required = "codex_hook_review_required"
    case changed = "codex_hook_changed"

    /// Only the adapter's pre-dispatch reserved error permits whole-operation replay.
    public static func classify(_ error: any Error) -> Self? {
        let rpc: JSONRPCError?
        if let direct = error as? JSONRPCError { rpc = direct }
        else if case ACPClientError.jsonrpc(let wrapped) = error { rpc = wrapped }
        else if let replay = error as? ACPBrokerDurableCompletionReplayError { rpc = replay.outcome.error }
        else { rpc = nil }
        guard let rpc, rpc.code == -32044,
              let data = rpc.data?.value as? [String: Any], let kind = data["kind"] as? String else { return nil }
        return Self(rawValue: kind)
    }
}
