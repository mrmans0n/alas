import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessError: Error {
    case launchFailed(String)
    case nonZeroExit(Int32, String)
}

extension Process {
    static func run(
        _ executable: String,
        args: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            if let cwd { process.currentDirectoryURL = cwd }
            if let env { process.environment = env }

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let result = ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProcessError.launchFailed(error.localizedDescription))
            }
        }
    }

    /// Convenience wrapper that always uses `/usr/bin/env git`.
    static func git(_ args: [String], cwd: URL? = nil) async throws -> ProcessResult {
        try await run("/usr/bin/env", args: ["git"] + args, cwd: cwd)
    }
}
