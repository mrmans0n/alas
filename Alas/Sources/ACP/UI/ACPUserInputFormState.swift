import Foundation
import Observation

@MainActor
@Observable
final class ACPUserInputFormState {
    let request: ACPUserInputRequest
    var textValues: [String: String] = [:]
    var booleanValues: [String: Bool] = [:]
    var selectionValues: [String: Set<String>] = [:]
    var dateValues: [String: Date] = [:]
    var touched: Set<String> = []
    private var presentByDefault: Set<String> = []
    var attemptedSubmit = false

    init(request: ACPUserInputRequest) {
        self.request = request
        for field in request.fields {
            seed(field)
            if presentByDefault.contains(field.key), validationError(for: field) != nil {
                clearSeededValue(for: field)
            }
        }
    }

    func markTouched(_ key: String) {
        touched.insert(key)
    }

    func toggle(_ option: String, for field: ACPUserInputField) {
        touched.insert(field.key)
        if field.schema.type == "array" {
            var selected = selectionValues[field.key] ?? []
            if selected.contains(option) {
                selected.remove(option)
            } else if field.schema.maxItems.map({ selected.count < $0 }) != false {
                selected.insert(option)
            }
            selectionValues[field.key] = selected
        } else {
            selectionValues[field.key] = [option]
        }
    }

    func validationError(for field: ACPUserInputField) -> String? {
        guard field.isSupported else {
            return field.required ? "This required field type is not supported." : nil
        }
        if !field.required,
           !touched.contains(field.key),
           !presentByDefault.contains(field.key) {
            return nil
        }
        switch field.schema.type {
        case "string" where !field.schema.options.isEmpty:
            let selected = selectionValues[field.key] ?? []
            if field.required && selected.isEmpty { return "Choose an option." }
            if !selected.isSubset(of: Set(field.schema.options.map(\.const))) {
                return "Choose a listed option."
            }
        case "string":
            if field.schema.format == "date" || field.schema.format == "date-time" {
                if dateValues[field.key] == nil, field.required {
                    return "Choose a date."
                }
                return nil
            }
            let value = textValues[field.key] ?? ""
            if value.isEmpty, !field.required { return nil }
            if let min = field.schema.minLength, value.count < min {
                return "Enter at least \(min) characters."
            }
            if let max = field.schema.maxLength, value.count > max {
                return "Enter no more than \(max) characters."
            }
            if let pattern = field.schema.pattern,
               let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(
                    in: value,
                    range: NSRange(value.startIndex..., in: value)
               ) == nil {
                return "The value does not match the requested format."
            }
            if let formatError = formatError(value, format: field.schema.format) {
                return formatError
            }
        case "number", "integer":
            let raw = textValues[field.key] ?? ""
            if raw.isEmpty && !field.required { return nil }
            guard let value = Double(raw), value.isFinite else { return "Enter a number." }
            if field.schema.type == "integer" {
                guard value.rounded() == value, Int(exactly: value) != nil else {
                    return "Enter a whole number."
                }
            }
            if let minimum = field.schema.minimum, value < minimum {
                return "Enter \(minimum) or greater."
            }
            if let maximum = field.schema.maximum, value > maximum {
                return "Enter \(maximum) or less."
            }
        case "array":
            let count = selectionValues[field.key]?.count ?? 0
            if field.required && count == 0 { return "Choose at least one option." }
            if let minimum = field.schema.minItems, count < minimum {
                return "Choose at least \(minimum) options."
            }
            if let maximum = field.schema.maxItems, count > maximum {
                return "Choose no more than \(maximum) options."
            }
            let allowed = Set(field.schema.options.map(\.const))
            if selectionValues[field.key]?.isSubset(of: allowed) == false {
                return "Choose only listed options."
            }
        case "boolean":
            break
        default:
            break
        }
        return nil
    }

    func submittedContent() -> [String: ACPElicitationValue]? {
        attemptedSubmit = true
        guard request.fields.allSatisfy({ validationError(for: $0) == nil }) else { return nil }
        var content: [String: ACPElicitationValue] = [:]
        for field in request.fields where shouldInclude(field) {
            switch field.schema.type {
            case "string" where !field.schema.options.isEmpty:
                if let value = selectionValues[field.key]?.first {
                    content[field.key] = .string(value)
                }
            case "string":
                if let date = dateValues[field.key] {
                    content[field.key] = .string(Self.format(date, as: field.schema.format))
                } else {
                    content[field.key] = .string(textValues[field.key] ?? "")
                }
            case "number":
                if let value = Double(textValues[field.key] ?? "") {
                    content[field.key] = .number(value)
                }
            case "integer":
                if let parsed = Double(textValues[field.key] ?? ""),
                   let value = Int(exactly: parsed) {
                    content[field.key] = .integer(value)
                }
            case "boolean":
                content[field.key] = .boolean(booleanValues[field.key] ?? false)
            case "array":
                let selected = selectionValues[field.key] ?? []
                let ordered = field.schema.options.map(\.const).filter(selected.contains)
                content[field.key] = .strings(ordered)
            default:
                break
            }
        }
        return content
    }

    func shouldShowError(for field: ACPUserInputField) -> Bool {
        attemptedSubmit || touched.contains(field.key) || !field.isSupported
    }

    private func shouldInclude(_ field: ACPUserInputField) -> Bool {
        if field.required { return true }
        switch field.schema.type {
        case "string" where !field.schema.options.isEmpty:
            return selectionValues[field.key]?.isEmpty == false
        case "string" where field.schema.format == "date" || field.schema.format == "date-time":
            return dateValues[field.key] != nil
        case "string":
            return textValues[field.key]?.isEmpty == false
        default:
            return touched.contains(field.key) || presentByDefault.contains(field.key)
        }
    }

    private func seed(_ field: ACPUserInputField) {
        guard let raw = field.schema.defaultValue?.value else {
            if field.schema.type == "boolean" { booleanValues[field.key] = false }
            return
        }
        switch field.schema.type {
        case "string":
            if let value = raw as? String {
                if field.schema.format == "date", let date = Self.parseDateOnly(value) {
                    dateValues[field.key] = date
                    presentByDefault.insert(field.key)
                } else if field.schema.format == "date-time",
                          let date = Self.parseDateTime(value) {
                    dateValues[field.key] = date
                    presentByDefault.insert(field.key)
                } else if field.schema.options.isEmpty,
                          field.schema.format != "date",
                          field.schema.format != "date-time" {
                    textValues[field.key] = value
                    presentByDefault.insert(field.key)
                } else if field.schema.options.contains(where: { $0.const == value }) {
                    selectionValues[field.key] = [value]
                    presentByDefault.insert(field.key)
                }
            }
        case "number", "integer":
            if raw is Bool {
                break
            } else if let value = raw as? NSNumber {
                textValues[field.key] = value.stringValue
                presentByDefault.insert(field.key)
            } else if let value = raw as? Int {
                textValues[field.key] = String(value)
                presentByDefault.insert(field.key)
            } else if let value = raw as? Double {
                textValues[field.key] = String(value)
                presentByDefault.insert(field.key)
            }
        case "boolean":
            if let value = raw as? Bool {
                booleanValues[field.key] = value
                presentByDefault.insert(field.key)
            }
        case "array":
            if let values = raw as? [AnyCodable] {
                selectionValues[field.key] = Set(values.compactMap { $0.value as? String })
                presentByDefault.insert(field.key)
            } else if let values = raw as? [String] {
                selectionValues[field.key] = Set(values)
                presentByDefault.insert(field.key)
            }
        default:
            break
        }
    }

    private func clearSeededValue(for field: ACPUserInputField) {
        textValues[field.key] = nil
        booleanValues[field.key] = field.schema.type == "boolean" ? false : nil
        selectionValues[field.key] = nil
        dateValues[field.key] = nil
        presentByDefault.remove(field.key)
    }

    private func formatError(_ value: String, format: String?) -> String? {
        switch format {
        case "email":
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[1].contains(".") ? nil : "Enter a valid email address."
        case "uri":
            return URL(string: value)?.scheme == nil ? "Enter a valid URI." : nil
        default:
            return nil
        }
    }

    private static func format(_ date: Date, as format: String?) -> String {
        if format == "date" {
            return formatDateOnly(date)
        }
        return date.ISO8601Format()
    }

    static func parseDateOnly(
        _ value: String,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date? {
        dateOnlyFormatter(timeZone: timeZone).date(from: value)
    }

    static func formatDateOnly(
        _ date: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        dateOnlyFormatter(timeZone: timeZone).string(from: date)
    }

    static func parseDateTime(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private static func dateOnlyFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
