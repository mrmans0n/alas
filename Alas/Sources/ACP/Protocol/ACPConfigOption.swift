import Foundation

/// Per-session configurable option advertised by the agent in
/// `session/new`. Wire format follows
/// https://agentclientprotocol.com/protocol/session-config-options —
/// we only render select-style options today.
struct ACPConfigOption: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String           // "select" today; other shapes accepted but rendered as empty
    let category: String?      // e.g. "ThoughtLevel" — used as a routing hint
    let currentValue: String?
    let options: [ACPConfigOptionItem]

    enum CodingKeys: String, CodingKey {
        case id, name, type, category, currentValue, options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = (try? c.decode(String.self, forKey: .type)) ?? "select"
        category = try? c.decode(String.self, forKey: .category)
        currentValue = try? c.decode(String.self, forKey: .currentValue)
        options = (try? c.decode([ACPConfigOptionItem].self, forKey: .options)) ?? []
    }

    init(id: String, name: String, type: String = "select",
         category: String? = nil, currentValue: String? = nil,
         options: [ACPConfigOptionItem] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.category = category
        self.currentValue = currentValue
        self.options = options
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(currentValue, forKey: .currentValue)
        try c.encode(options, forKey: .options)
    }
}

struct ACPConfigOptionItem: Codable, Equatable, Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?

    init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// Params for the `session/set_config_option` request — the method that
/// pushes a new selected value back to the agent.
struct ACPSessionSetConfigOptionParams: Codable, Equatable {
    let sessionId: String
    let configId: String
    let value: String
}
