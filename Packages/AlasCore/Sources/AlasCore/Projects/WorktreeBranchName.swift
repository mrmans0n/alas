import Foundation

public enum WorktreeBranchName: Sendable {
    /// Blank settings inherit the next layer; absent templates preserve the
    /// legacy prefix and typed name without sanitizing either.
    public static func compose(
        name: String,
        prefix: String,
        globalTemplate: String? = nil,
        projectTemplate: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard let template = normalizedTemplate(projectTemplate) ?? normalizedTemplate(globalTemplate) else {
            return prefix + name
        }
        return render(template: template, name: name, now: now, calendar: calendar)
    }

    public static func normalizedTemplate(_ template: String?) -> String? {
        guard let value = template?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Expands `{name}`, `{date}` and `{time}` and sanitizes the result into
    /// something git accepts as a branch name.
    public static func render(template: String, name: String, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyyMMdd"
        let timeFormatter = DateFormatter()
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "HHmm"
        let expanded = template
            .replacingOccurrences(of: "{name}", with: slug(name))
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: now))
            .replacingOccurrences(of: "{time}", with: timeFormatter.string(from: now))
        let cleaned = sanitizeBranch(expanded)
        return cleaned.isEmpty ? "scheduled-\(dateFormatter.string(from: now))-\(timeFormatter.string(from: now))" : cleaned
    }

    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    /// Renders a template into something `GitNameValidator` accepts. A user
    /// is free to type any template, and it is expanded unattended at fire
    /// time, so anything git would reject has to be repaired here rather than
    /// turning every firing into a launch failure.
    ///
    /// git's rules, per component between slashes: no leading dot, no
    /// trailing dot, no `.lock` suffix, no `..`, and no empty component.
    private static func sanitizeBranch(_ text: String) -> String {
        var mapped = ""
        var previousWasDash = false
        for character in text {
            if "/._-".contains(character) {
                mapped.append(character)
                previousWasDash = character == "-"
                continue
            }
            let isAllowed = character.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            }
            if isAllowed {
                mapped.append(character)
                previousWasDash = false
            } else if !previousWasDash {
                mapped.append("-")
                previousWasDash = true
            }
        }
        let components = mapped
            .split(separator: "/", omittingEmptySubsequences: true)
            .compactMap { raw -> String? in
                var component = String(raw)
                while component.contains("..") {
                    component = component.replacingOccurrences(of: "..", with: ".")
                }
                while let first = component.first, first == "." || first == "-" {
                    component.removeFirst()
                }
                while true {
                    if component.lowercased().hasSuffix(".lock") {
                        component.removeLast(5)
                        continue
                    }
                    if let last = component.last, last == "." || last == "-" {
                        component.removeLast()
                        continue
                    }
                    break
                }
                return component.isEmpty ? nil : component
            }
        return components.joined(separator: "/")
    }
}
