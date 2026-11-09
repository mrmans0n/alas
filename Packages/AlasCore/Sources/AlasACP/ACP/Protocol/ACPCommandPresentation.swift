import Foundation
import AlasModel

/// What an adapter says about one of its available commands in the
/// client-neutral `_meta.commandPresentation` record: whether it is a skill,
/// where its `SKILL.md` lives on the adapter's host, and a command action that
/// Alas can run with its own session controls. Alas never runs anything the
/// record names except a validated config change, and never infers a
/// presentation from a command's name.
public struct ACPCommandPresentation: Codable, Equatable, Hashable, Sendable {
    /// The command is a skill. A skill bundled with the agent has no file.
    public let isSkill: Bool
    /// The absolute path of the skill's `SKILL.md`, on the adapter's host.
    public let skillPath: String?
    public let action: ACPCommandAction?

    public init(isSkill: Bool = false, skillPath: String? = nil, action: ACPCommandAction? = nil) {
        self.isSkill = isSkill
        self.skillPath = isSkill ? skillPath : nil
        self.action = action
    }

    /// The record of one wire command, or nil when nothing usable remains:
    /// another version, a path that is not absolute, an unknown action kind,
    /// or a config action without its id or value.
    init?(wire: Wire) {
        guard wire.version == 1 else { return nil }
        let isSkill = wire.kind == "skill"
        let path = wire.skillPath.flatMap { $0.hasPrefix("/") ? $0 : nil }
        let action = wire.action.flatMap(ACPCommandAction.init(wire:))
        guard isSkill || action != nil else { return nil }
        self.init(isSkill: isSkill, skillPath: path, action: action)
    }

    struct Wire: Decodable {
        let version: Int?
        let kind: String?
        let skillPath: String?
        let action: ActionWire?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try? c.decodeIfPresent(Int.self, forKey: .version)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            skillPath = try? c.decodeIfPresent(String.self, forKey: .skillPath)
            action = try? c.decodeIfPresent(ActionWire.self, forKey: .action)
        }

        enum CodingKeys: String, CodingKey { case version, kind, skillPath, action }
    }

    struct ActionWire: Decodable {
        let kind: String?
        let configId: String?
        let value: String?
        let resetValue: String?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            configId = try? c.decodeIfPresent(String.self, forKey: .configId)
            value = try? c.decodeIfPresent(String.self, forKey: .value)
            resetValue = try? c.decodeIfPresent(String.self, forKey: .resetValue)
        }

        enum CodingKeys: String, CodingKey { case kind, configId, value, resetValue }
    }
}

/// A command action the adapter negotiated for one of its commands.
public enum ACPCommandAction: Codable, Equatable, Hashable, Sendable {
    /// Picking the command sets a config option to `value`, or back to
    /// `resetValue` when it already has `value`.
    case setConfigOption(configId: String, value: String, resetValue: String?)
    /// The command prefixes the prompt. Alas's command chip already does that.
    case prefixPrompt

    init?(wire: ACPCommandPresentation.ActionWire) {
        switch wire.kind {
        case "setConfigOption":
            guard let configId = wire.configId, !configId.isEmpty,
                  let value = wire.value, !value.isEmpty else { return nil }
            self = .setConfigOption(
                configId: configId,
                value: value,
                resetValue: wire.resetValue.flatMap { $0.isEmpty ? nil : $0 }
            )
        case "prefixPrompt":
            self = .prefixPrompt
        default:
            return nil
        }
    }

    /// What picking the command does against the session's live config
    /// options. Checked at use, so an action that went stale with the config
    /// or the provider falls back to the ordinary command.
    public func resolve(in options: [ACPConfigOption]) -> ACPCommandActionResolution {
        guard case .setConfigOption(let configId, let value, let resetValue) = self,
              let option = options.first(where: { $0.id == configId }),
              option.type == "select",
              option.acceptsPersistedValue(.string(value)) else { return .unsupported }
        guard option.currentStringValue == value else {
            return .apply(configId: configId, value: value)
        }
        guard let resetValue, resetValue != value,
              option.acceptsPersistedValue(.string(resetValue)) else { return .noop }
        return .apply(configId: configId, value: resetValue)
    }

    /// Whether the config option currently has the action's value, or nil when
    /// the action does not apply to the live config.
    public func isOn(in options: [ACPConfigOption]) -> Bool? {
        guard case .setConfigOption(let configId, let value, _) = self,
              resolve(in: options) != .unsupported else { return nil }
        return options.first(where: { $0.id == configId })?.currentStringValue == value
    }
}

public enum ACPCommandActionResolution: Equatable, Sendable {
    /// Set the config option to this value.
    case apply(configId: String, value: String)
    /// The option already has the value and there is nothing to reset to.
    case noop
    /// Not a config action, or one the live config cannot take: use the
    /// ordinary command.
    case unsupported
}

/// Where a skill's `SKILL.md` opens. The adapter reports a path on its own
/// host, so a remote session's path moves onto that host's virtual tree and
/// never names a local file of the same path.
public enum ACPSkillFileRoute: Equatable, Sendable {
    /// Inside the session's worktree: an ordinary editor tab.
    case worktreeFile(relativePath: String)
    /// Outside it: a read-only external editor tab on that path.
    case external(path: String)

    public static func route(skillPath: String, worktreeRoot: String) -> ACPSkillFileRoute {
        let target = URL(fileURLWithPath: RemotePath.virtualizing(skillPath, like: worktreeRoot))
            .standardizedFileURL.path
        let root = URL(fileURLWithPath: worktreeRoot).standardizedFileURL.path
        guard target.hasPrefix(root + "/") else { return .external(path: target) }
        return .worktreeFile(relativePath: String(target.dropFirst(root.count + 1)))
    }
}
