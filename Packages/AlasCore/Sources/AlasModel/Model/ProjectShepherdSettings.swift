import Foundation

/// Per-project shepherd rules stored in `ProjectConfig.shepherd`.
public struct ProjectShepherdSettings: Codable, Equatable, Sendable {
    public var instructions: String
    public var requiredReviewers: [String]

    private enum CodingKeys: String, CodingKey {
        case instructions, requiredReviewers
    }

    public init(instructions: String = "", requiredReviewers: [String] = []) {
        self.instructions = instructions
        self.requiredReviewers = requiredReviewers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? ""
        requiredReviewers = (try? c.decode([String].self, forKey: .requiredReviewers)) ?? []
    }

    public var isEmpty: Bool {
        instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.normalizedReviewers(requiredReviewers).isEmpty
    }

    /// Reviewer logins lowercased, without a leading `@`, blanks or repeats.
    package static func normalizedReviewers(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in raw {
            var login = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if login.hasPrefix("@") { login.removeFirst() }
            guard !login.isEmpty, seen.insert(login).inserted else { continue }
            result.append(login)
        }
        return result
    }
}
