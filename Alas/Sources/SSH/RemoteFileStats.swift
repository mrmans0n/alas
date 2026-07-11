import Foundation
import OSLog

enum RemoteFileStats {
    private static let logger = Logger(subsystem: "app.alas", category: "RemoteFileStats")
    static let maxBatchedPaths = 200

    static func wcCommand(paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        return "wc -l " + paths.map(SSHCommand.shellQuote).joined(separator: " ")
    }

    static func parseWcOutput(_ output: String, requested: [String]) -> [String: Int] {
        let requested = Set(requested)
        return output.split(separator: "\n").reduce(into: [:]) { counts, line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: " "), let count = Int(line[..<separator]) else { return }
            let path = String(line[line.index(after: separator)...])
            if requested.contains(path) { counts[path] = count }
        }
    }

    static func lineCounts(host: String, cwd: String, paths: [String]) async -> [String: Int] {
        let paths = Array(paths.prefix(maxBatchedPaths))
        guard let command = wcCommand(paths: paths),
              let result = try? await RemoteExec.run(host: host, cwd: cwd, command: command),
              !RemoteExec.isConnectionFailure(exitCode: result.exitCode)
        else { return [:] }
        return parseWcOutput(result.stdout, requested: paths)
    }

    static func parseLsEntries(_ output: String) -> [(name: String, isDirectory: Bool)] {
        output.split(separator: "\n").map {
            let name = String($0)
            return name.hasSuffix("/") ? (String(name.dropLast()), true) : (name, false)
        }
    }
}
