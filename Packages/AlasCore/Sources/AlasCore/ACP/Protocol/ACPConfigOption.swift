import Foundation

public enum ACPConfigValue: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) {
            self = .boolean(b)
            return
        }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try c.encode(value)
        case .boolean(let value):
            try c.encode(value)
        }
    }
}

/// Per-session configurable option advertised by the agent in
/// `session/new`. Wire format follows
/// https://agentclientprotocol.com/protocol/session-config-options —
/// select options are rendered as chips, boolean options as toggles.
public struct ACPConfigOption: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: String           // "select" or negotiated "boolean"; other shapes ignored
    public let category: String?      // e.g. "ThoughtLevel" — used as a routing hint
    public let currentValue: ACPConfigValue?
    public let options: [ACPConfigOptionItem]

    public var currentStringValue: String? {
        guard case .string(let value) = currentValue else { return nil }
        return value
    }

    public var currentBoolValue: Bool? {
        guard case .boolean(let value) = currentValue else { return nil }
        return value
    }

    public enum CodingKeys: String, CodingKey, Sendable {
        case id, name, type, category, currentValue, options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(String.self, forKey: .type)) ?? "select"
        category = try? c.decode(String.self, forKey: .category)
        currentValue = try? c.decode(ACPConfigValue.self, forKey: .currentValue)
        options = (try? c.decode([ACPConfigOptionItem].self, forKey: .options)) ?? []
    }

    public init(id: String, name: String, type: String = "select",
         category: String? = nil, currentValue: String? = nil,
         options: [ACPConfigOptionItem] = []) {
        self.init(
            id: id,
            name: name,
            type: type,
            category: category,
            currentValue: currentValue.map(ACPConfigValue.string),
            options: options)
    }

    public init(id: String, name: String, type: String = "select",
         category: String? = nil, currentValue: ACPConfigValue?,
         options: [ACPConfigOptionItem] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.category = category
        self.currentValue = currentValue
        self.options = options
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(currentValue, forKey: .currentValue)
        try c.encode(options, forKey: .options)
    }

    public static func currentValues(in options: [ACPConfigOption]) -> [String: ACPConfigValue] {
        var values: [String: ACPConfigValue] = [:]
        values.reserveCapacity(options.count)
        for option in options {
            if let value = option.currentValue {
                values[option.id] = value
            }
        }
        return values
    }

    public func acceptsPersistedValue(_ value: ACPConfigValue) -> Bool {
        switch (type, value) {
        case ("boolean", .boolean):
            return true
        case ("select", .string(let id)):
            return options.contains { $0.id == id }
        default:
            return false
        }
    }

    public static func mergingSuccessfulSetResponse(
        _ configOptions: [ACPConfigOption],
        configId: String,
        selectedValue: ACPConfigValue,
        currentConfigOptions: [ACPConfigOption],
        baselineConfigOptions: [ACPConfigOption]? = nil,
        baselineConfigOptionsRevision: Int? = nil,
        currentConfigOptionsRevision: Int? = nil
    ) -> [ACPConfigOption]? {
        guard currentConfigOptions.first(where: { $0.id == configId })?.currentValue == selectedValue else {
            return nil
        }

        var merged: [ACPConfigOption] = []
        for option in configOptions {
            if option.id == configId {
                if let baselineConfigOptions,
                   let baseline = baselineConfigOptions.first(where: { $0.id == option.id }),
                   let current = currentConfigOptions.first(where: { $0.id == option.id }),
                   current != baseline {
                    merged.append(current)
                    continue
                }
                merged.append(ACPConfigOption(
                    id: option.id,
                    name: option.name,
                    type: option.type,
                    category: option.category,
                    currentValue: selectedValue,
                    options: option.options))
                continue
            }
            if let baselineConfigOptions,
               let baseline = baselineConfigOptions.first(where: { $0.id == option.id }) {
                guard let current = currentConfigOptions.first(where: { $0.id == option.id }) else {
                    continue
                }
                merged.append(current == baseline ? option : current)
                continue
            }
            if let baselineConfigOptions,
               baselineConfigOptions.contains(where: { $0.id == option.id }) == false {
                if let current = currentConfigOptions.first(where: { $0.id == option.id }) {
                    merged.append(current)
                } else if baselineConfigOptionsRevision == nil
                    || baselineConfigOptionsRevision == currentConfigOptionsRevision {
                    merged.append(option)
                }
                continue
            }
            merged.append(option)
        }
        if let baselineConfigOptions {
            let mergedIds = Set(merged.map(\.id))
            merged.append(contentsOf: currentConfigOptions.filter { current in
                guard !mergedIds.contains(current.id) else { return false }
                guard let baseline = baselineConfigOptions.first(where: { $0.id == current.id }) else {
                    return true
                }
                return current != baseline
            })
        }
        return merged
    }
}

public struct ACPConfigOptionItem: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let description: String?
    public let kind: ACPModeKind?

    public init(id: String, name: String, description: String? = nil, kind: ACPModeKind? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
    }

    // Wire format uses `value` for the option identifier; accept both
    // shapes so older draft payloads (which used `id`) keep decoding.
    public enum CodingKeys: String, CodingKey, Sendable { case id, value, name, description, meta = "_meta" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .value) {
            id = v
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        name = try c.decode(String.self, forKey: .name)
        description = try? c.decode(String.self, forKey: .description)
        let meta = (try? c.decodeIfPresent(ACPModeKindMetadata.self, forKey: .meta)) ?? nil
        kind = meta?.kind.flatMap(ACPModeKind.init(rawValue:))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .value)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

/// Params for the `session/set_config_option` request — the method that
/// pushes a new selected value back to the agent.
public struct ACPSessionSetConfigOptionParams: Codable, Equatable, Sendable {
    public let sessionId: String
    public let configId: String
    public let value: ACPConfigValue

    public enum CodingKeys: String, CodingKey, Sendable {
        case sessionId, configId, type, value
    }

    public init(sessionId: String, configId: String, value: ACPConfigValue) {
        self.sessionId = sessionId
        self.configId = configId
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        configId = try c.decode(String.self, forKey: .configId)
        value = try c.decode(ACPConfigValue.self, forKey: .value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(configId, forKey: .configId)
        switch value {
        case .string:
            try c.encode("id", forKey: .type)
        case .boolean:
            try c.encode("boolean", forKey: .type)
        }
        try c.encode(value, forKey: .value)
    }
}

/// Result of `session/set_config_option`. The agent returns the complete
/// refreshed `configOptions` list because a single change can ripple to
/// dependent options (e.g. codex's reasoning effort altering available
/// model variants). Empty when the agent doesn't echo state back; the
/// caller keeps its optimistic local update in that case.
public struct ACPSessionSetConfigOptionResult: Codable, Equatable, Sendable {
    public let configOptions: [ACPConfigOption]

    public enum CodingKeys: String, CodingKey, Sendable { case configOptions }

    public init(configOptions: [ACPConfigOption] = []) {
        self.configOptions = configOptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configOptions = (try? c.decode([ACPConfigOption].self, forKey: .configOptions)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configOptions, forKey: .configOptions)
    }
}
