import AlasAgentKit
import AlasModel
import Foundation

public enum HostSettingSection: String, CaseIterable, Sendable {
    case reachability, agents, behavior, worktrees
}

public enum HostSettingKind: Equatable, Sendable {
    case bool, port, text, path, choice([String])
}

public enum HostSettingError: Error, Equatable, LocalizedError {
    case unknownKey(String)
    case invalidValue(key: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .unknownKey(let key): "Unknown setting '\(key)'."
        case .invalidValue(let key, let expected): "Invalid value for '\(key)': expected \(expected)."
        }
    }
}

/// One setting `alas-host` can read and write, with its parsing and printing.
public struct HostSetting: Sendable {
    public let key: String
    public let section: HostSettingSection
    public let title: String
    public let kind: HostSettingKind
    private let read: @Sendable (AppConfig) -> String
    private let write: @Sendable (String, inout AppConfig) throws(HostSettingError) -> Void

    public func value(in config: AppConfig) -> String { read(config) }

    public func set(_ value: String, in config: inout AppConfig) throws(HostSettingError) {
        try write(value, &config)
    }

    init(
        _ key: String, _ section: HostSettingSection, _ title: String, _ kind: HostSettingKind,
        read: @escaping @Sendable (AppConfig) -> String,
        write: @escaping @Sendable (String, inout AppConfig) throws(HostSettingError) -> Void
    ) {
        self.key = key
        self.section = section
        self.title = title
        self.kind = kind
        self.read = read
        self.write = write
    }

    private static func parseBool(_ key: String, _ raw: String) throws(HostSettingError) -> Bool {
        switch raw.lowercased() {
        case "true", "on", "yes": return true
        case "false", "off", "no": return false
        default: throw .invalidValue(key: key, expected: "true|false|on|off|yes|no")
        }
    }

    static func bool(
        _ key: String, _ section: HostSettingSection, _ title: String,
        get: @escaping @Sendable (AppConfig) -> Bool,
        set: @escaping @Sendable (inout AppConfig, Bool) -> Void
    ) -> HostSetting {
        HostSetting(key, section, title, .bool, read: { get($0) ? "true" : "false" }) { raw, config throws(HostSettingError) in
            set(&config, try parseBool(key, raw))
        }
    }

    static func text(
        _ key: String, _ section: HostSettingSection, _ title: String, kind: HostSettingKind = .text,
        get: @escaping @Sendable (AppConfig) -> String,
        set: @escaping @Sendable (inout AppConfig, String) -> Void
    ) -> HostSetting {
        HostSetting(key, section, title, kind, read: get) { raw, config in set(&config, raw) }
    }
}

public enum HostSettingCatalog {
    public static func all(for config: AppConfig) -> [HostSetting] {
        var settings: [HostSetting] = [
            HostSetting(
                "host.reachability", .reachability, "Reachability",
                .choice(HostReachability.allCases.map(\.rawValue)),
                read: { $0.hostReachability.rawValue }
            ) { raw, config throws(HostSettingError) in
                guard let value = HostReachability(rawValue: raw) else {
                    throw .invalidValue(key: "host.reachability", expected: HostReachability.allCases.map(\.rawValue).joined(separator: "|"))
                }
                config.host.reachability = value
            },
            HostSetting("host.port", .reachability, "Port", .port, read: { String($0.hostPort) }) { raw, config throws(HostSettingError) in
                guard let value = UInt16(raw), value > 0 else {
                    throw .invalidValue(key: "host.port", expected: "a port from 1 to 65535")
                }
                config.host.port = value
            },
            .text("remote.displayName", .reachability, "Display name", get: { $0.remote.displayName }, set: { $0.remote.displayName = $1 }),
        ]

        for agent in AgentBuiltins.catalog {
            let id = agent.id
            settings.append(.bool(
                "agents.\(id).enabled", .agents, "\(agent.displayName) enabled",
                get: { config in
                    AgentConfiguredCatalog.all(builtinState: config.agents.builtinState, customs: [])
                        .first { $0.id == id }?.isEnabled ?? false
                },
                set: { config, value in
                    config.agents.builtinState[id, default: BuiltinAgentState(isEnabled: value)].isEnabled = value
                }
            ))
        }
        for installed in config.agents.registry {
            let id = installed.registryID
            settings.append(.bool(
                "agents.\(id).enabled", .agents, "\(installed.displayName) enabled",
                get: { config in config.agents.registry.first { $0.registryID == id }?.isEnabled ?? false },
                set: { config, value in
                    if let i = config.agents.registry.firstIndex(where: { $0.registryID == id }) {
                        config.agents.registry[i].isEnabled = value
                    }
                }
            ))
        }

        settings += [
            .bool("harness.acpAutoRunByDefault", .behavior, "Auto-run tools by default",
                  get: { $0.harness.acpAutoRunByDefault }, set: { $0.harness.acpAutoRunByDefault = $1 }),
            .bool("harness.acpAutoResumeAfterUsageLimit", .behavior, "Auto-resume after usage limit",
                  get: { $0.harness.acpAutoResumeAfterUsageLimit }, set: { $0.harness.acpAutoResumeAfterUsageLimit = $1 }),
            .bool("harness.acpContinueInterruptedSessions", .behavior, "Continue interrupted sessions",
                  get: { $0.harness.acpContinueInterruptedSessions }, set: { $0.harness.acpContinueInterruptedSessions = $1 }),
            .text("worktrees.rootPath", .worktrees, "Worktrees root", kind: .path,
                  get: { $0.worktrees.rootPath }, set: { $0.worktrees.rootPath = $1 }),
            .text("worktrees.baseBranch", .worktrees, "Base branch",
                  get: { $0.worktrees.baseBranch }, set: { $0.worktrees.baseBranch = $1 }),
        ]
        return settings
    }

    public static func named(_ key: String, in config: AppConfig) throws(HostSettingError) -> HostSetting {
        guard let setting = all(for: config).first(where: { $0.key == key }) else { throw .unknownKey(key) }
        return setting
    }
}
