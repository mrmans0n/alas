import Foundation

/// How a worktree VM is named in the registry. A worktree may have one VM per guest OS; the macOS
/// VM keeps the plain worktree id that builds from before Linux guests wrote, and other guests
/// take a `<guest>:` prefix. Worktree ids are standardized absolute paths, so they start with `/`
/// and can never be read as a prefixed id (a suffix could: `/repo/demo#linux` is a valid path).
public enum VMIdentity {
    /// Golden images for Linux guests are recorded under this prefix in `goldenBuild`.
    public static let linuxGoldenPrefix = "golden-linux:"
    /// `guestOS` of the stub record that keeps a Linux-only worktree visible to builds that predate
    /// Linux guests. Deliberately not a `VMGuestOS` case, so no build ever decodes the stub.
    public static let aliasGuestRaw = "linux-alias"

    private static let linuxPrefix = "linux:"

    public static func recordID(worktree: String, guest: VMGuestOS) -> String {
        switch guest {
        case .macOS: worktree
        case .linux: linuxPrefix + worktree
        }
    }

    public static func parse(recordID: String) -> (worktree: String, guest: VMGuestOS) {
        guard recordID.hasPrefix(linuxPrefix) else { return (recordID, .macOS) }
        return (String(recordID.dropFirst(linuxPrefix.count)), .linux)
    }
}
