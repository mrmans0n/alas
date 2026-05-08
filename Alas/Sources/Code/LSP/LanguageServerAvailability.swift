import Foundation

struct LanguageServerAvailability {
    enum Status: Equatable {
        case disabled
        case available
        case notInstalled
    }

    private let environment: [String: String]
    private let fileManager: FileManager
    private let xcrunFind: (String) -> Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        xcrunFind: @escaping (String) -> Bool = LanguageServerAvailability.xcrunFind
    ) {
        self.environment = environment
        self.fileManager = fileManager
        self.xcrunFind = xcrunFind
    }

    func status(for entry: LanguageServerConfig) -> Status {
        guard entry.enabled else { return .disabled }
        guard !entry.command.isEmpty else { return .notInstalled }

        if entry.command.contains("/") {
            return fileManager.isExecutableFile(atPath: entry.command) ? .available : .notInstalled
        }

        if executableNamed(entry.command) != nil {
            return .available
        }

        if entry.language == "swift", entry.command == "sourcekit-lsp", xcrunFind("sourcekit-lsp") {
            return .available
        }

        return .notInstalled
    }

    private func executableNamed(_ name: String) -> String? {
        let path = environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func xcrunFind(_ tool: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--find", tool]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
