import Foundation

/// Installs and verifies the bundled Alas helper in the app's private remote
/// directory. Consent is owned by AppState so upgrades can reuse it.
enum RemoteHelperInstaller {
    #if arch(arm64)
    static let localArch = "aarch64"
    #else
    static let localArch = "x86_64"
    #endif

    static func bundledBinaryPath(
        os: RemoteHostCapabilities.OS,
        arch: String?,
        resourceURL: URL
    ) -> URL? {
        guard let arch else { return nil }
        let directory: String
        switch (os, arch) {
        case (.linux, "x86_64"):
            directory = "linux-x86_64"
        case (.linux, "aarch64"):
            directory = "linux-aarch64"
        case (.macos, "x86_64"):
            directory = "macos-x86_64"
        case (.macos, "aarch64"):
            directory = "macos-aarch64"
        default:
            return nil
        }
        return resourceURL.appendingPathComponent("alas-helper/\(directory)/alas-helper")
    }

    static func bundledHandshake(resourceURL: URL) -> RemoteHelperHandshake? {
        let manifest = resourceURL.appendingPathComponent("alas-helper/manifest.json")
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        return try? JSONDecoder().decode(RemoteHelperHandshake.self, from: data)
    }

    static func needsInstall(
        remote: RemoteHelperHandshake?,
        bundled: RemoteHelperHandshake
    ) -> Bool {
        remote != bundled
    }

    static func install(
        host: String,
        capabilities: RemoteHostCapabilities,
        resourceURL: URL
    ) async -> Bool {
        guard let expected = bundledHandshake(resourceURL: resourceURL),
              let binary = bundledBinaryPath(
                  os: capabilities.os,
                  arch: capabilities.arch,
                  resourceURL: resourceURL
              ),
              FileManager.default.isExecutableFile(atPath: binary.path)
        else { return false }

        guard let mkdir = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: "mkdir -p \"$HOME/.alas/bin\"",
            timeout: 10
        ), mkdir.exitCode == 0 else { return false }

        guard let copy = try? await Process.run(
            SSHCommand.scpExecutable,
            args: SSHCommand.scpArgv(
                localPath: binary.path,
                host: host,
                remotePath: ".alas/bin/alas-helper.tmp"
            ),
            timeout: 60
        ), copy.exitCode == 0 else { return false }

        guard let verify = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: "chmod +x \"$HOME/.alas/bin/alas-helper.tmp\" && "
                + "\"$HOME/.alas/bin/alas-helper.tmp\" version",
            timeout: 10
        ), verify.exitCode == 0,
        RemoteHelperHandshake.decode(verify.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == expected
        else {
            _ = try? await RemoteExec.run(
                host: host,
                cwd: nil,
                command: "rm -f \"$HOME/.alas/bin/alas-helper.tmp\"",
                timeout: 10
            )
            return false
        }

        guard let finalize = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: "mv \"$HOME/.alas/bin/alas-helper.tmp\" \"$HOME/.alas/bin/alas-helper\"",
            timeout: 10
        ), finalize.exitCode == 0 else {
            _ = try? await RemoteExec.run(
                host: host,
                cwd: nil,
                command: "rm -f \"$HOME/.alas/bin/alas-helper.tmp\"",
                timeout: 10
            )
            return false
        }
        return true
    }
}
