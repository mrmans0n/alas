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

    static func lineCountDictionary(_ entries: [RemoteHelperFSLineCountEntry]) -> [String: Int] {
        entries.reduce(into: [:]) { counts, entry in
            counts[entry.path] = entry.lineCount
        }
    }

    static func lineCounts(host: String, cwd: String, paths: [String]) async -> [String: Int] {
        guard !paths.isEmpty else { return [:] }
        if await RemoteHostCapabilityStore.shared.capabilities(for: host)?.helperHandshake != nil {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let result = try await client.lineCounts(root: cwd, paths: paths)
                RemoteOperationTiming.log("fs/line-counts", host: host, transport: "helper", startedAt: startedAt)
                return lineCountDictionary(result.entries)
            } catch let error as RemoteHelperClientError where !error.shouldFallbackToRemoteExec {
                RemoteOperationTiming.log("fs/line-counts", host: host, transport: "helper", startedAt: startedAt)
                logger.debug("helper line counts failed: \(String(describing: error), privacy: .public)")
                return [:]
            } catch {
                RemoteOperationTiming.log("fs/line-counts", host: host, transport: "helper-fallback", startedAt: startedAt)
            }
        }

        let fallbackPaths = Array(paths.prefix(maxBatchedPaths))
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { RemoteOperationTiming.log("fs/line-counts", host: host, transport: "exec", startedAt: startedAt) }
        guard let command = wcCommand(paths: fallbackPaths),
              let result = try? await RemoteExec.run(host: host, cwd: cwd, command: command),
              !RemoteExec.isConnectionFailure(exitCode: result.exitCode)
        else { return [:] }
        return parseWcOutput(result.stdout, requested: fallbackPaths)
    }

    static func directoryEntries(host: String, path: String) async -> [(name: String, isDirectory: Bool)] {
        if await RemoteHostCapabilityStore.shared.capabilities(for: host)?.helperHandshake != nil {
            let startedAt = CFAbsoluteTimeGetCurrent()
            do {
                let client = await RemoteHelperClientPool.shared.client(for: host)
                let result = try await client.list(path: path)
                RemoteOperationTiming.log("fs/list", host: host, transport: "helper", startedAt: startedAt)
                return result.entries.map { ($0.name, $0.isDirectory) }
            } catch let error as RemoteHelperClientError where !error.shouldFallbackToRemoteExec {
                RemoteOperationTiming.log("fs/list", host: host, transport: "helper", startedAt: startedAt)
                logger.debug("helper directory listing failed: \(String(describing: error), privacy: .public)")
                return []
            } catch {
                RemoteOperationTiming.log("fs/list", host: host, transport: "helper-fallback", startedAt: startedAt)
            }
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        defer { RemoteOperationTiming.log("fs/list", host: host, transport: "exec", startedAt: startedAt) }
        guard let result = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: "ls -1Ap " + SSHCommand.shellQuote(path)
        ), result.exitCode == 0 else { return [] }
        return parseLsEntries(result.stdout)
    }

    static func parseLsEntries(_ output: String) -> [(name: String, isDirectory: Bool)] {
        output.split(separator: "\n").map {
            let name = String($0)
            return name.hasSuffix("/") ? (String(name.dropLast()), true) : (name, false)
        }
    }
}
