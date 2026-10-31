import Foundation

/// How a worktree VM is named in the registry. A worktree may have one VM per guest OS; the macOS
/// VM keeps the plain worktree id that builds from before Linux guests wrote, and other guests
/// append a `#<guest>` suffix.
public enum VMIdentity {
    /// Golden images for Linux guests are recorded under this prefix in `goldenBuild`.
    public static let linuxGoldenPrefix = "golden-linux:"
    /// `guestOS` of the stub record that keeps a Linux-only worktree visible to builds that predate
    /// Linux guests. Deliberately not a `VMGuestOS` case, so no build ever decodes the stub.
    public static let aliasGuestRaw = "linux-alias"

    private static let linuxSuffix = "#linux"

    public static func recordID(worktree: String, guest: VMGuestOS) -> String {
        switch guest {
        case .macOS: worktree
        case .linux: worktree + linuxSuffix
        }
    }

    public static func parse(recordID: String) -> (worktree: String, guest: VMGuestOS) {
        guard recordID.hasSuffix(linuxSuffix) else { return (recordID, .macOS) }
        return (String(recordID.dropLast(linuxSuffix.count)), .linux)
    }
}
