import Foundation

/// What the user entered for one elicitation field. A missing key means untouched.
public enum RemoteElicitationInput: Equatable, Sendable {
    case text(String)
    case toggle(Bool)
    case selection([String])
    case date(Date)
}

public struct RemoteElicitationFormError: Error, Equatable, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// Builds `elicitationResponse` content from phone form input. Ports the web's
/// `submitElicitation` rules, enforcing the HTML constraints explicitly.
public enum RemoteElicitationForm {
    private static let supportedTypes: Set<String> = ["string", "number", "integer", "boolean", "array"]

    public static func initialInputs(_ fields: [RemoteElicitationField]) -> [String: RemoteElicitationInput] {
        var inputs: [String: RemoteElicitationInput] = [:]
        for field in fields where supportedTypes.contains(field.type) {
            guard let value = field.defaultValue else { continue }
            switch (value, field.type) {
            case (.strings(let items), _): inputs[field.key] = .selection(items)
            case (.string(let s), _) where isSelection(field): inputs[field.key] = .selection([s])
            case (.boolean(let b), "boolean"): inputs[field.key] = .toggle(b)
            case (.string(let s), _):
                if field.format == "date" || field.format == "date-time", let d = parseDate(s) {
                    inputs[field.key] = .date(d)
                } else {
                    inputs[field.key] = .text(s)
                }
            case (.integer(let i), _): inputs[field.key] = .text(String(i))
            case (.number(let d), _): inputs[field.key] = .text(String(d))
            case (.boolean, _): break
            }
        }
        return inputs
    }

    public static func content(
        _ fields: [RemoteElicitationField],
        inputs: [String: RemoteElicitationInput]
    ) -> Result<[String: ACPElicitationValue], RemoteElicitationFormError> {
        var content: [String: ACPElicitationValue] = [:]
        for field in fields {
            do {
                if let value = try encode(field, inputs[field.key]) { content[field.key] = value }
            } catch let error as RemoteElicitationFormError {
                return .failure(error)
            } catch {
                return .failure(RemoteElicitationFormError(message: "Check the value for \(field.title)."))
            }
        }
        return .success(content)
    }

    private static func isSelection(_ field: RemoteElicitationField) -> Bool {
        (field.type == "string" && !field.options.isEmpty) || field.type == "array"
    }

    private static func encode(_ field: RemoteElicitationField, _ input: RemoteElicitationInput?) throws -> ACPElicitationValue? {
        let invalid = RemoteElicitationFormError(message: "Check the value for \(field.title).")
        guard supportedTypes.contains(field.type) else {
            if field.required {
                throw RemoteElicitationFormError(message: "Cannot submit the unsupported field \(field.title).")
            }
            return nil
        }

        if isSelection(field) {
            if input == nil, !field.required { return nil }
            var chosen: [String] = []
            if let input {
                guard case .selection(let items) = input else { throw invalid }
                chosen = items
            }
            if field.required, chosen.isEmpty {
                throw RemoteElicitationFormError(message: "Choose a value for \(field.title).")
            }
            if let minItems = field.minItems, minItems > 0, chosen.count < minItems {
                throw RemoteElicitationFormError(message: "Choose at least \(minItems) values for \(field.title).")
            }
            if let maxItems = field.maxItems, maxItems > 0, chosen.count > maxItems { throw invalid }
            if field.type == "array" { return .strings(chosen) }
            return chosen.first.map { .string($0) }
        }

        if field.type == "boolean" {
            switch input {
            case nil: return field.required ? .boolean(false) : nil
            case .toggle(let on): return .boolean(on)
            default: throw invalid
            }
        }

        // string, number, integer
        let isDateFormat = field.format == "date" || field.format == "date-time"
        let raw: String
        switch input {
        case nil, .text(""):
            if !field.required { return nil }
            raw = ""
        case .text(let text) where !isDateFormat: raw = text
        case .date(let date) where isDateFormat:
            return .string(formatDate(date, dateOnly: field.format == "date"))
        default: throw invalid
        }

        if field.required, missing(field, raw) {
            throw RemoteElicitationFormError(message: "Enter a value for \(field.title).")
        }
        if let max = field.maxLength, raw.utf16.count > max { throw invalid }
        if let min = field.minLength, raw.utf16.count < min { throw invalid }
        if !matchesPattern(field, raw) { throw invalid }

        switch field.type {
        case "number", "integer":
            guard let number = Double(raw.trimmingCharacters(in: .whitespaces)), number.isFinite else { throw invalid }
            if let min = field.minimum, number < min { throw invalid }
            if let max = field.maximum, number > max { throw invalid }
            if field.type == "number" { return .number(number) }
            guard let whole = Int(exactly: number) else {
                throw RemoteElicitationFormError(message: "Enter a whole number for \(field.title).")
            }
            return .integer(whole)
        default:
            if field.format == "email", !isEmail(raw) { throw invalid }
            if field.format == "uri", URL(string: raw)?.scheme == nil { throw invalid }
            return .string(raw)
        }
    }

    private static func missing(_ field: RemoteElicitationField, _ value: String) -> Bool {
        guard value.isEmpty else { return false }
        if field.type == "number" || field.type == "integer" { return true }
        if ["date", "date-time", "email", "uri"].contains(field.format ?? "") { return true }
        if let min = field.minLength, min > 0 { return true }
        if field.pattern != nil { return !matchesPattern(field, value) }
        return false
    }

    /// An invalid pattern is ignored, as on the web.
    private static func matchesPattern(_ field: RemoteElicitationField, _ value: String) -> Bool {
        guard let pattern = field.pattern, let regex = try? NSRegularExpression(pattern: pattern) else { return true }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func isEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }

    private static func formatDate(_ date: Date, dateOnly: Bool) -> String {
        if dateOnly {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"  // the picker's local day
            return f.string(from: date)
        }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func parseDate(_ raw: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: raw) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }
}
