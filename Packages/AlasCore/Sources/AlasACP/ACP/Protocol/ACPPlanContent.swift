import Foundation
import AlasCode

/// The content of a standard ACP `plan_update` (`PlanUpdateContent`). Each
/// update replaces whatever the client stored for its `planId`.
public enum ACPPlanContent: Equatable, Sendable {
    case items([ACPPlanEntry])
    case markdown(String)
    case file(uri: String)
    /// A content type this client does not know yet. Kept so the plan id stays
    /// addressable (a later update or `plan_removed` can still target it).
    case unknown(type: String)

    /// The v2 `planValue` rules: object with string `type` and `planId`; `items` needs an
    /// `entries` array whose entries have string content/priority/status; `markdown` needs
    /// string `content`; `file` needs string `uri`; any other type is `.unknown`.
    /// Throws DecodingError on violation. `_meta` must be an object (or null) when present.
    public static func parse(_ raw: LSPJSONValue) throws -> (planId: String, content: ACPPlanContent) {
        let fields = try object(raw)
        let type = try requiredString(fields, "type")
        let planId = try requiredString(fields, "planId")
        try validateMetadata(fields["_meta"])
        switch type {
        case "items":
            guard let value = fields["entries"] else { throw invalid("plan entries are required") }
            let entries = try array(value).map { entry in
                let item = try object(entry)
                try validateMetadata(item["_meta"])
                return ACPPlanEntry(content: try requiredString(item, "content"),
                    priority: try requiredString(item, "priority"), status: try requiredString(item, "status"))
            }
            return (planId, .items(entries))
        case "markdown":
            return (planId, .markdown(try requiredString(fields, "content")))
        case "file":
            return (planId, .file(uri: try requiredString(fields, "uri")))
        default:
            return (planId, .unknown(type: type))
        }
    }

    private static func validateMetadata(_ value: LSPJSONValue?) throws {
        switch value {
        case nil, .null, .object: return
        default: throw invalid("_meta must be an object or null")
        }
    }

    private static func requiredString(_ fields: [String: LSPJSONValue], _ key: String) throws -> String {
        guard case .string(let value)? = fields[key] else { throw invalid("\(key) must be a string") }
        return value
    }

    private static func object(_ value: LSPJSONValue) throws -> [String: LSPJSONValue] {
        guard case .object(let fields) = value else { throw invalid("expected an object") }
        return fields
    }

    private static func array(_ value: LSPJSONValue) throws -> [LSPJSONValue] {
        guard case .array(let items) = value else { throw invalid("expected an array") }
        return items
    }

    private static func invalid(_ reason: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Invalid plan_update: \(reason)"))
    }
}

/// A standard ACP `plan_update`: the whole content of one identified plan.
public struct ACPPlanUpdate: Equatable, Sendable {
    public let planId: String
    public let content: ACPPlanContent

    public init(planId: String, content: ACPPlanContent) {
        self.planId = planId
        self.content = content
    }
}
