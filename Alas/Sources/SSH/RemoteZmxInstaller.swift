import Foundation

/// Installs the bundled zmx helper in Alas' private remote directory. The
/// caller owns consent; this type only performs bounded batch operations.
enum RemoteZmxInstaller {
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
        switch (os, arch) {
        case (.linux, "x86_64"):
            return resourceURL.appendingPathComponent("zmx/linux-x86_64/zmx")
        case (.linux, "aarch64"):
            return resourceURL.appendingPathComponent("zmx/linux-aarch64/zmx")
        case (.macos, let remoteArch) where remoteArch == localArch:
            return resourceURL.appendingPathComponent("zmx/zmx")
        default:
            return nil
        }
    }

    static func install(
        host: String,
        capabilities: RemoteHostCapabilities,
        resourceURL: URL
    ) async -> Bool {
        guard let binary = bundledBinaryPath(
            os: capabilities.os,
            arch: capabilities.arch,
            resourceURL: resourceURL
        ), FileManager.default.isExecutableFile(atPath: binary.path) else {
            return false
        }

        guard let mkdir = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: "mkdir -p \"$HOME/.alas/bin\"",
            timeout: 10
        ), mkdir.exitCode == 0 else {
            return false
        }

        guard let copy = try? await Process.run(
            SSHCommand.scpExecutable,
            args: SSHCommand.scpArgv(
                localPath: binary.path,
                host: host,
                remotePath: ".alas/bin/zmx.tmp"
            ),
            timeout: 60
        ), copy.exitCode == 0 else {
            return false
        }

        guard let finalize = try? await RemoteExec.run(
            host: host,
            cwd: nil,
            command: "chmod +x \"$HOME/.alas/bin/zmx.tmp\" && "
                + "mv \"$HOME/.alas/bin/zmx.tmp\" \"$HOME/.alas/bin/zmx\" && "
                + "[ -x \"$HOME/.alas/bin/zmx\" ]",
            timeout: 10
        ) else {
            return false
        }
        return finalize.exitCode == 0
    }
}
