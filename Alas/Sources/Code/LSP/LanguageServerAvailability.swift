import Foundation

struct LanguageServerAvailability {
    enum Status: Equatable {
        case disabled
        case available
        case notInstalled
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let xcrunFind: (String) -> String?
    private let additionalPathDirectories: [String]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        xcrunFind: @escaping (String) -> String? = LanguageServerAvailability.xcrunFind,
        additionalPathDirectories: [String] = LanguageServerAvailability.defaultAdditionalPathDirectories()
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.xcrunFind = xcrunFind
        self.additionalPathDirectories = additionalPathDirectories
    }

    func status(for entry: LanguageServerConfig) -> Status {
        guard entry.enabled else { return .disabled }
        return resolvedCommand(for: entry) != nil ? .available : .notInstalled
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

    private static func defaultAdditionalPathDirectories() -> [String] {
        var dirs: [String] = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.bun/bin",
            "\(NSHomeDirectory())/.volta/bin"
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

    private static func pathFileEntries(at path: String) -> [String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func xcrunFind(_ tool: String) -> String? {
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
