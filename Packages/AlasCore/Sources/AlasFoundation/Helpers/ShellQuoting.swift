import Foundation

public enum ShellQuoting: Sendable {
    /// Returns `s` unchanged when it holds only shell-safe characters,
    /// otherwise wraps it in POSIX single quotes.
    public static func quote(_ s: String) -> String {
        if s.range(of: "[^A-Za-z0-9_/.@%+=,:-]", options: .regularExpression) == nil {
            return s
        }
        // POSIX single-quote escape: end the quoted string, insert an
        // escaped quote, restart the quoted string.
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
