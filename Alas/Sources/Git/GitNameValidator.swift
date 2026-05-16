import Foundation

/// Validates git branch names and worktree names to prevent invalid refs
/// and filesystem-unsafe paths before shelling out to git.
struct GitNameValidator {
    enum ValidationResult: Equatable {
        case valid
        case invalid(String)
    }

    /// Validate a git branch name according to git ref naming rules.
    /// Allows path-style names such as `feature/foo`.
    static func validateBranchName(_ name: String) -> ValidationResult {
        // Do NOT trim spaces — if the user includes them, they are invalid.
        // We only reject truly empty strings after stripping all characters.
        if name.isEmpty {
            return .invalid("Name cannot be empty.")
        }

        if name.count > 250 {
            return .invalid("Name is too long (max 250 characters).")
        }

        if name.contains(" ") {
            return .invalid("Name cannot contain spaces.")
        }

        if name.unicodeScalars.contains(where: { $0.isASCII && $0.properties.generalCategory == .control }) {
            return .invalid("Name cannot contain control characters.")
        }

        if name.hasPrefix("/") || name.hasSuffix("/") {
            return .invalid("Name cannot start or end with '/' .")
        }

        if name.contains("//") {
            return .invalid("Name cannot contain consecutive '/' .")
        }

        if name.contains("@{") {
            return .invalid("Name cannot contain '@{' .")
        }

        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            let comp = String(component)

            if comp == "." || comp == ".." {
                return .invalid("Name cannot contain '.' or '..' as a path component.")
            }

            if comp.hasPrefix(".") || comp.hasSuffix(".") {
                return .invalid("Path components cannot start or end with '.'.")
            }

            if comp.contains("..") {
                return .invalid("Name cannot contain '..'.")
            }

            if comp.hasPrefix("-") {
                return .invalid("Path components cannot start with '-' .")
            }

            if comp.hasSuffix(".lock") {
                return .invalid("Name cannot end with '.lock' .")
            }

            for ch in comp {
                if ch == "~" || ch == "^" || ch == ":" || ch == "\\" || ch == "\t" {
                    return .invalid("Name contains unsupported characters.")
                }
                if ch == "\r" || ch == "\n" || ch == "\0" || ch == "{" || ch == "}" {
                    return .invalid("Name contains unsupported characters.")
                }
                if ch == "?" || ch == "*" {
                    return .invalid("Name contains unsupported characters.")
                }
            }
        }

        return .valid
    }

    /// Validate a worktree directory name derived from a branch name.
    static func validateWorktreeName(_ name: String) -> ValidationResult {
        validateBranchName(name)
    }
}
