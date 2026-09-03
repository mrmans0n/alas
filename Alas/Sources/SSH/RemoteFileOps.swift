import Foundation

/// POSIX-portable filesystem operations used for remote editor path changes.
enum RemoteFileOps {
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
