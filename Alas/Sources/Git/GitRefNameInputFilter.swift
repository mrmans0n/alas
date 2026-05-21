import Foundation

struct GitRefNameInputFilter: Equatable {
    enum Mode {
        case editing
        case paste
    }

    static let branchName = GitRefNameInputFilter(allowsTrailingSlashOnPaste: false)
    static let branchPrefix = GitRefNameInputFilter(allowsTrailingSlashOnPaste: true)
    static let refName = GitRefNameInputFilter(allowsTrailingSlashOnPaste: false)

    private let allowsTrailingSlashOnPaste: Bool

    private init(allowsTrailingSlashOnPaste: Bool) {
        self.allowsTrailingSlashOnPaste = allowsTrailingSlashOnPaste
    }

    func sanitize(_ rawValue: String, mode: Mode) -> String {
        let filteredScalars = rawValue.unicodeScalars.compactMap { scalar -> UnicodeScalar? in
            if scalar.properties.generalCategory == .control { return nil }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            if Self.forbiddenScalars.contains(scalar) { return nil }
            return scalar
        }
        var value = String(String.UnicodeScalarView(filteredScalars))

        value = value.replacingOccurrences(of: "@{", with: "@")
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        while value.hasPrefix("/") {
            value.removeFirst()
        }

        var components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for index in components.indices {
            components[index] = sanitizeComponent(
                components[index],
                mode: mode,
                isFirstComponent: index == components.startIndex
            )
        }

        while components.first == "" {
            components.removeFirst()
        }
        while components.count > 1, components.dropLast().contains("") {
            if let index = components.dropLast().firstIndex(of: "") {
                components.remove(at: index)
            }
        }

        if mode == .paste && !allowsTrailingSlashOnPaste {
            while components.last == "" {
                components.removeLast()
            }
        }

        return components.joined(separator: "/")
    }

    func applyingReplacement(to currentValue: String, range: NSRange, replacement: String) -> String {
        let current = currentValue as NSString
        let next = current.replacingCharacters(in: range, with: replacement)
        let mode: Mode = replacement.count > 1 ? .paste : .editing
        return sanitize(next, mode: mode)
    }

    private func sanitizeComponent(_ rawComponent: String, mode: Mode, isFirstComponent: Bool) -> String {
        var component = rawComponent
        while component.hasPrefix(".") {
            component.removeFirst()
        }
        while isFirstComponent && component.hasPrefix("-") {
            component.removeFirst()
        }
        while component.contains("..") {
            component = component.replacingOccurrences(of: "..", with: ".")
        }
        while component.hasSuffix(".lock") {
            component.removeLast(".lock".count)
        }
        if mode == .paste {
            while component.hasSuffix(".") {
                component.removeLast()
            }
        }
        if component == "@" {
            return ""
        }
        return component
    }

    private static let forbiddenScalars = Set("~^:?*[\\".unicodeScalars)
}
