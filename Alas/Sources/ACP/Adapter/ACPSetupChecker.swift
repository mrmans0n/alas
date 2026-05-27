import Foundation

struct ACPSetupChecker {
    let env: [String: String]

    func evaluate(_ check: ACPSetupCheck) async -> ACPSetupResult {
        switch check {
        case .binaryOnPath(let name):
            return resolve(name) != nil
                ? .ready
                : .missing(reason: "`\(name)` not found on PATH")
        case .npxPackage(let pkg):
            return await npmPackageInstalled(pkg)
                ? .ready
                : .missing(reason: "npm package `\(pkg)` is not installed globally")
        case .binaryOnPathOrNpmPackage(let bin, let pkg):
            if resolve(bin) != nil { return .ready }
            if await npmPackageInstalled(pkg) { return .ready }
            return .missing(reason: "`\(bin)` not on PATH and `\(pkg)` not installed")
        }
    }

    private func resolve(_ name: String) -> String? {
        let pathValue = env["PATH"] ?? ""
        for dir in pathValue.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private func npmPackageInstalled(_ name: String) async -> Bool {
        // `npm root -g` resolves the global node_modules path; look for the package there.
        guard let npm = resolve("npm") else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: npm)
        proc.arguments = ["root", "-g"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let root = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: "\(root)/\(name)", isDirectory: &isDir) && isDir.boolValue
    }
}
