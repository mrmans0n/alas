import Foundation
import AlasCode

/// A conservative flat-schema validator. Unsupported constraints never count
/// as validation success; a caller can supply a validator for custom schemas.
public enum ACPV2FormAnswerValidator {
    public enum Result: Equatable, Sendable { case valid, invalid(String), unsupported(String) }
    private static let annotations: Set<String> = ["title", "description", "_meta", "default"]

    public static func validate(schema: LSPJSONValue, content: LSPJSONValue?) -> Result {
        guard case .object(let root) = schema, root["type"] == nil || root["type"] == .string("object"),
              Set(root.keys).isSubset(of: annotations.union(["type", "properties", "required"])) else { return .unsupported("Unsupported form schema") }
        let properties: [String: LSPJSONValue]
        if let raw = root["properties"] { guard case .object(let value) = raw else { return .unsupported("Invalid properties") }
        properties = value }
        else { properties = [:] }
        let required: [String]
        if let raw = root["required"], raw != .null {
            guard let values = strings(raw), Set(values.map { Data($0.utf8) }).count == values.count else { return .unsupported("Invalid required fields") }
            required = values
        } else { required = [] }
        let answers: [String: LSPJSONValue]
        if let content, content != .null { guard case .object(let fields) = content else { return .invalid("Expected form object") }
        answers = fields }
        else { answers = [:] }
        for key in required {
            guard let property = properties[key], case .object(let fields) = property,
                  case .string(let type)? = fields["type"], ["string", "number", "integer", "boolean", "array"].contains(type) else { return .unsupported("Unsupported required field") }
        }
        guard required.allSatisfy({ answers[$0] != nil }) else { return .invalid("Missing required answer") }
        for (key, value) in answers {
            guard let property = properties[key] else { return .invalid("Unknown answered field") }
            let result = validateProperty(property, value: value)
            if result != .valid { return result }
        }
        return .valid
    }

    private static func validateProperty(_ schema: LSPJSONValue, value: LSPJSONValue) -> Result {
        guard case .object(let fields) = schema, case .string(let type)? = fields["type"] else { return .unsupported("Unknown property schema") }
        let allowed: Set<String>
        switch type {
        case "string": allowed = annotations.union(["type", "enum", "oneOf", "minLength", "maxLength", "format"])
        case "number", "integer", "boolean": allowed = annotations.union(["type"])
        case "array": allowed = annotations.union(["type", "items", "minItems", "maxItems"])
        default: return .unsupported("Unknown property type")
        }
        guard Set(fields.keys).isSubset(of: allowed) else { return .unsupported("Unsupported validation keyword") }
        switch type {
        case "string":
            if let format = fields["format"] {
                guard case .string(let name) = format else { return .unsupported("Invalid format") }
                if ["email", "uri", "date", "date-time"].contains(name) { return .unsupported("Format validation unavailable") }
            }
            let choice = choices(fields, array: false)
            if case .failure(let error) = choice { return error }
            guard case .string(let text) = value else { return .invalid("Expected string") }
            if case .success(let options?) = choice, !options.contains(where: { $0.utf8.elementsEqual(text.utf8) }) { return .invalid("Unknown choice") }
            return bounds(fields, count: text.unicodeScalars.count, min: "minLength", max: "maxLength")
        case "number":
            guard case .number(let token) = value, (try? LSPJSONValue.number(token).encodedData()) != nil else { return .invalid("Expected number") }
            return .valid
        case "integer":
            guard case .number(let token) = value, integral(token) else { return .invalid("Expected integer") }
            return .valid
        case "boolean": guard case .bool = value else { return .invalid("Expected boolean") }
        return .valid
        default:
            guard case .object(let items)? = fields["items"] else { return .unsupported("Missing array choices") }
            let choice = choices(items, array: true)
            guard case .success(let options?) = choice else {
                if case .failure(let error) = choice { return error }
                return .unsupported("Missing array choices")
            }
            guard let values = strings(value) else { return .invalid("Expected string array") }
            guard values.allSatisfy({ item in options.contains { $0.utf8.elementsEqual(item.utf8) } }) else { return .invalid("Unknown array choice") }
            return bounds(fields, count: values.count, min: "minItems", max: "maxItems")
        }
    }

    // Result itself is not Error, so keep parsing alternatives explicit.
    private enum Choices { case success([String]?), failure(Result) }
    private static func choices(_ fields: [String: LSPJSONValue], array: Bool) -> Choices {
        let alternative = array ? "anyOf" : "oneOf"
        if fields["enum"] != nil, fields[alternative] != nil { return .failure(.unsupported("Conflicting choices")) }
        var values: [String]?
        if let raw = fields["enum"] {
            guard !array || fields["type"] == .string("string"), let parsed = strings(raw), !parsed.isEmpty else { return .failure(.unsupported("Invalid enum")) }
            values = parsed
        } else if let raw = fields[alternative] {
            guard case .array(let options) = raw, !options.isEmpty else { return .failure(.unsupported("Invalid choices")) }
            var parsed: [String] = []
            for item in options {
                guard case .object(let option) = item, case .string(let text)? = option["const"],
                      Set(option.keys).isSubset(of: annotations.union(["const"])) else { return .failure(.unsupported("Invalid choice option")) }
                parsed.append(text)
            }
            values = parsed
        }
        if let values, Set(values.map { Data($0.utf8) }).count != values.count { return .failure(.unsupported("Duplicate choices")) }
        if array, let type = fields["type"], type != .string("string") { return .failure(.unsupported("Array items must be strings")) }
        if array, !Set(fields.keys).isSubset(of: annotations.union(["type", "enum", "anyOf"])) { return .failure(.unsupported("Unsupported array constraint")) }
        return .success(values)
    }

    private static func bounds(_ fields: [String: LSPJSONValue], count: Int, min: String, max: String) -> Result {
        var limits: [String: Int] = [:]
        for key in [min, max] {
            if let raw = fields[key] {
                guard case .number(let token) = raw, let value = Int(token), value >= 0 else { return .unsupported("Invalid bound") }
                limits[key] = value
            }
        }
        if let low = limits[min], let high = limits[max], low > high { return .unsupported("Conflicting bounds") }
        if let low = limits[min], count < low { return .invalid("Answer too short") }
        if let high = limits[max], count > high { return .invalid("Answer too long") }
        return .valid
    }
    private static func strings(_ raw: LSPJSONValue) -> [String]? {
        guard case .array(let values) = raw else { return nil }
        var strings: [String] = []
        for value in values { guard case .string(let text) = value else { return nil }
        strings.append(text) }
        return strings
    }
    private static func integral(_ token: String) -> Bool {
        guard (try? LSPJSONValue.number(token).encodedData()) != nil else { return false }
        let components = token.lowercased().split(separator: "e", omittingEmptySubsequences: false)
        let coefficient = components[0].filter { $0 != "-" && $0 != "." }
        if coefficient.allSatisfy({ $0 == "0" }) { return true }
        let fraction = components[0].split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        let exponent: Int
        if components.count == 2 {
            guard let value = Int(components[1]) else { return !components[1].hasPrefix("-") }
            exponent = value
        } else { exponent = 0 }
        let (scale, overflow) = fraction.subtractingReportingOverflow(exponent)
        if overflow { return false }
        return scale <= coefficient.reversed().prefix(while: { $0 == "0" }).count
    }
}
