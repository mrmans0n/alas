import Foundation

/// The kind of work a ticket asks for. It selects the instructions of the
/// first chat prompt. `nil` wherever an `IssueKind?` appears means
/// unclassified, which keeps the generic prompt.
enum IssueKind: String, Codable, CaseIterable, Sendable {
    case bug, enhancement, research, docs, chore

    var displayName: String {
        switch self {
        case .bug: "Bug"
        case .enhancement: "Enhancement"
        case .research: "Research"
        case .docs: "Docs"
        case .chore: "Chore"
        }
    }
}

/// Where the current kind came from. `.user` is never overwritten by the rules.
enum IssueKindOrigin: Equatable, Codable, Sendable {
    case rule(reason: String)
    case user
}

struct IssueKindDecision: Equatable, Sendable {
    let kind: IssueKind
    let reason: String
}

/// Deterministic classification from provider metadata. Native issue types
/// win over labels. Labels that point at more than one kind decide nothing,
/// so the ticket keeps the generic prompt.
enum IssueKindRules {
    static func classify(_ source: IssueSnapshot) -> IssueKindDecision? {
        nativeDecision(source) ?? labelDecision(source.labels)
    }

    private static func nativeDecision(_ source: IssueSnapshot) -> IssueKindDecision? {
        guard let raw = source.nativeType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let value = raw.lowercased()
        let provider = source.identity.providerID
        if provider == .github {
            switch value {
            case "bug": return .init(kind: .bug, reason: "from GitHub issue type \(raw)")
            case "feature", "enhancement": return .init(kind: .enhancement, reason: "from GitHub issue type \(raw)")
            default: return nil
            }
        }
        if provider == .gitlab {
            switch value {
            case "incident": return .init(kind: .bug, reason: "from GitLab incident")
            case "test_case": return .init(kind: .chore, reason: "from GitLab test case")
            default: return nil
            }
        }
        return nil
    }

    private static let synonyms: [String: IssueKind] = [
        "bug": .bug, "defect": .bug, "regression": .bug, "crash": .bug, "incident": .bug,
        "enhancement": .enhancement, "feature": .enhancement, "feature request": .enhancement,
        "improvement": .enhancement,
        "research": .research, "spike": .research, "investigation": .research,
        "discovery": .research, "rfc": .research, "question": .research,
        "docs": .docs, "documentation": .docs,
        "chore": .chore, "refactor": .chore, "maintenance": .chore, "tech debt": .chore,
        "cleanup": .chore, "dependencies": .chore,
    ]

    private static func labelDecision(_ labels: [String]) -> IssueKindDecision? {
        let matches = labels.compactMap { label in synonyms[normalize(label)].map { (kind: $0, label: label) } }
        guard let first = matches.first,
              matches.allSatisfy({ $0.kind == first.kind }) else { return nil }
        return .init(kind: first.kind, reason: "from label \"\(first.label)\"")
    }

    /// Reduces `type::bug`, `bug::vulnerability`, `kind/docs`,
    /// `Feature-Request` and `tech_debt` to the synonym table's spelling.
    /// For a GitLab scoped label, a `type`/`kind` scope uses its value, and
    /// any other scope is checked as the kind itself.
    private static func normalize(_ label: String) -> String {
        var value = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scoped = value.components(separatedBy: "::")
        if scoped.count > 1 {
            value = ["type", "kind"].contains(scoped[0]) ? scoped[scoped.count - 1] : scoped[0]
        } else if let slash = value.firstIndex(of: "/"), ["type", "kind"].contains(String(value[..<slash])) {
            value = String(value[value.index(after: slash)...])
        }
        return value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
