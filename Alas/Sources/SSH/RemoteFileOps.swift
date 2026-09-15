import Foundation
import CryptoKit

/// POSIX-portable filesystem operations used for remote editor path changes.
enum RemoteFileOps {
    /// Guards exact regular-file targets. Hashes keep expected file contents
    /// out of the remote command and diagnostics. A final external-writer race
    /// remains between the guard and mutation, as with local atomic rename.
    static func contentGuard(path: String, expected: Data?) -> String {
        let prefix = "p=\(SSHCommand.shellQuote(path)); [ ! -L \"$p\" ] && [ ! -d \"$p\" ] || exit 42; "
        guard let expected else { return prefix + "[ ! -e \"$p\" ] || exit 42; " }
        let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        return prefix + "[ -f \"$p\" ] || exit 42; "
            + "h=$(shasum -a 256 < \"$p\" 2>/dev/null || sha256sum < \"$p\") || exit 42; "
            + "[ \"${h%% *}\" = \(SSHCommand.shellQuote(digest)) ] || exit 42; "
    }

    static func guardedMoveCommand(from: String, to: String, expectedSource: Data, expectedDestination: Data?) -> String {
        contentGuard(path: from, expected: expectedSource)
            + contentGuard(path: to, expected: expectedDestination)
            + "mv -f \(SSHCommand.shellQuote(from)) \(SSHCommand.shellQuote(to))"
    }

    /// Replacement bytes arrive over stdin; only hashes and exact paths are
    /// embedded in the command. Deletes never recurse.
    static func guardedReplaceCommand(path: String, expected: Data?, replacement: Data?, permissions: Int? = nil) -> String {
        let guardScript = contentGuard(path: path, expected: expected)
        guard replacement != nil else { return guardScript + "rm -f \(SSHCommand.shellQuote(path))" }
        return guardScript + RemoteFileAccess.writeScript(path: path, permissions: permissions)
    }

    static func mkdirCommand(parentOf path: String) -> String {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return "mkdir -p \(SSHCommand.shellQuote(parent))"
    }

    static func moveCommand(from: String, to: String) -> String {
        let quotedSource = SSHCommand.shellQuote(from)
        let quotedDestination = SSHCommand.shellQuote(to)
        return "\(mkdirCommand(parentOf: to)) && [ ! -e \(quotedDestination) ] && [ ! -L \(quotedDestination) ] && mv \(quotedSource) \(quotedDestination)"
    }

    static func removeCommand(path: String) -> String {
        "p=\(SSHCommand.shellQuote(path)); rm -rf \"$p\""
    }

    static func createEmptyFileCommand(path: String) -> String {
        let quotedPath = SSHCommand.shellQuote(path)
        return "\(mkdirCommand(parentOf: path)) && f=\(quotedPath) && [ ! -e \"$f\" ] && [ ! -L \"$f\" ] && (set -C; : > \"$f\")"
    }

    static func createDirectoryCommand(path: String) -> String {
        let quotedPath = SSHCommand.shellQuote(path)
        return "d=\(quotedPath); [ ! -e \"$d\" ] && [ ! -L \"$d\" ] && mkdir \"$d\""
    }
}
