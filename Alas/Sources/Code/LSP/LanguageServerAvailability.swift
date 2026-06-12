import Foundation

@MainActor
struct LanguageServerAvailability {
    enum Status: Equatable {
        case disabled
        case available
        case notInstalled
        case blockedByGatekeeper(realPath: String)
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let xcrunFind: (String) -> String?
    private let additionalPathDirectories: [String]
    private let gatekeeperAssessor: (String) -> GatekeeperAssessor.Result
    private let gatekeeperRemediator: (String) async -> GatekeeperRemediator.Outcome

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        xcrunFind: @escaping (String) -> String? = LanguageServerAvailability.xcrunFind,
        additionalPathDirectories: [String] = LanguageServerAvailability.defaultAdditionalPathDirectories(),
        gatekeeperAssessor: @escaping (String) -> GatekeeperAssessor.Result = { GatekeeperAssessor.shared.assess(realPath: $0) },
        gatekeeperRemediator: @escaping (String) async -> GatekeeperRemediator.Outcome = {
            await GatekeeperRemediator().remediate(realPath: $0)
        }
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.xcrunFind = xcrunFind
        self.additionalPathDirectories = additionalPathDirectories
        self.gatekeeperAssessor = gatekeeperAssessor
        self.gatekeeperRemediator = gatekeeperRemediator
    }

    func status(for entry: LanguageServerConfig) -> Status {
        guard entry.enabled else { return .disabled }
        guard let resolved = resolvedCommand(for: entry) else { return .notInstalled }
        var assessedRealPaths = Set<String>()
        let primary = gatekeeperStatus(forResolvedPath: resolved)
        assessedRealPaths.insert((resolved as NSString).resolvingSymlinksInPath)
        guard primary == .available else { return primary }

        for helper in entry.gatekeeperHelpers {
            guard let helperPath = resolvedHelper(helper, env: entry.env) else { continue }
            let helperRealPath = (helperPath as NSString).resolvingSymlinksInPath
            guard assessedRealPaths.insert(helperRealPath).inserted else { continue }
            let helperStatus = gatekeeperStatus(forResolvedPath: helperRealPath)
            guard helperStatus == .available else { return helperStatus }
        }

        return .available
    }

    func statusRemediatingGatekeeper(for entry: LanguageServerConfig) async -> Status {
        let maxAttempts = entry.gatekeeperHelpers.count + 1

        for _ in 0..<maxAttempts {
            let current = status(for: entry)
            guard case .blockedByGatekeeper(let realPath) = current else {
                return current
            }

            switch await gatekeeperRemediator(realPath) {
            case .allowed:
                continue
            case .stillBlocked, .failed:
                return .blockedByGatekeeper(realPath: realPath)
            }
        }

        return status(for: entry)
    }

    private func gatekeeperStatus(forResolvedPath resolved: String) -> Status {
        let realPath = (resolved as NSString).resolvingSymlinksInPath
        switch gatekeeperAssessor(realPath) {
        case .rejected:
            return .blockedByGatekeeper(realPath: realPath)
        case .allowed, .unknown:
            return .available
        }
    }

    func resolvedCommand(for entry: LanguageServerConfig) -> String? {
        guard entry.enabled, !entry.command.isEmpty else { return nil }

        if entry.command.contains("/") {
            return fileManager.isExecutableFile(atPath: entry.command) ? entry.command : nil
        }

        if let pathHit = executableNamed(entry.command, env: entry.env) {
            return pathHit
        }

        if entry.language == "swift", entry.command == "sourcekit-lsp",
           let xcrunPath = xcrunFind("sourcekit-lsp") {
            return xcrunPath
        }

        return nil
    }

    func spawnArguments(for entry: LanguageServerConfig) -> (executable: String, arguments: [String])? {
        guard let resolved = resolvedCommand(for: entry) else { return nil }
        if resolved.contains("/") {
            return (executable: resolved, arguments: entry.args)
        }
        return (executable: "/usr/bin/env", arguments: [resolved] + entry.args)
    }

    func launchEnvironment(for entry: LanguageServerConfig) -> [String: String] {
        var merged = environment
        for (key, value) in entry.env {
            merged[key] = value
        }
        merged["PATH"] = effectivePath(env: entry.env)
        return merged
    }

    private func resolvedHelper(_ helper: String, env: [String: String]) -> String? {
        if helper.contains("/") {
            return fileManager.isExecutableFile(atPath: helper) ? helper : nil
        }
        return executableNamed(helper, env: env)
    }

    private func executableNamed(_ name: String, env: [String: String] = [:]) -> String? {
        for dir in effectivePath(env: env).split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func effectivePath(env: [String: String]) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for path in [env["PATH"], environment["PATH"]] {
            for dir in pathEntries(path) where seen.insert(dir).inserted {
                parts.append(dir)
            }
        }
        for dir in additionalPathDirectories where !dir.isEmpty && seen.insert(dir).inserted {
            parts.append(dir)
        }
        return parts.joined(separator: ":")
    }

    private func pathEntries(_ path: String?) -> [String] {
        guard let path else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    nonisolated private static func defaultAdditionalPathDirectories() -> [String] {
        var dirs: [String] = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.bun/bin",
            "\(NSHomeDirectory())/.volta/bin",
            // Default GOPATH/bin for `go install`-placed binaries (gopls, etc.).
            "\(NSHomeDirectory())/go/bin"
        ]

        dirs.append(contentsOf: pathFileEntries(at: "/etc/paths"))

        let pathsD = "/etc/paths.d"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: pathsD) {
            for entry in entries.sorted() {
                dirs.append(contentsOf: pathFileEntries(at: "\(pathsD)/\(entry)"))
            }
        }

        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated private static func pathFileEntries(at path: String) -> [String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    nonisolated private static func xcrunFind(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", tool]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? nil : output
        } catch {
            return nil
        }
    }
}
