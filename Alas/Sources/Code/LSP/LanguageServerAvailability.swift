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

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        xcrunFind: @escaping (String) -> String? = LanguageServerAvailability.xcrunFind
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.xcrunFind = xcrunFind
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

    private func executableNamed(_ name: String, env: [String: String] = [:]) -> String? {
        let mergedPath: String
        if let envPath = env["PATH"], !envPath.isEmpty {
            let basePath = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            mergedPath = envPath + ":" + basePath
        } else {
            mergedPath = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        for dir in mergedPath.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
