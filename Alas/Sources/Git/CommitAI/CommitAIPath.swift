import Foundation

/// Computes a PATH string suitable for finding commit-message AI CLIs from
/// inside Alas. Needed because a macOS GUI app inherits launchd's minimal
/// PATH (typically `/usr/bin:/bin:/usr/sbin:/sbin` + `/etc/paths.d/*`) and
/// therefore can't see tools the user installed into `/opt/homebrew/bin`,
/// `~/.local/bin`, etc.
enum CommitAIPath {
    /// Well-known directories where commit-AI CLIs are commonly installed.
    /// Order is preserved when appending. Tilde-form entries are expanded
    /// at lookup time.
    static let wellKnownDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.local/bin",
        "~/.bun/bin",
        "~/.cargo/bin",
        "~/.deno/bin",
        "~/Library/pnpm",
        "~/.npm-global/bin",
        "~/.volta/bin",
    ]

    /// Returns `base` (or the process PATH if `base` is nil) with the
    /// well-known directories appended.
    static func augmented(base: String? = nil) -> String {
        let basePath = base ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        return augment(base: basePath, wellKnown: wellKnownDirectories)
    }

    /// Pure: tilde-expands each `wellKnown` entry, drops those that don't
    /// exist on disk, drops those whose expanded form already appears in
    /// `base`, and appends the rest to `base` in order.
    static func augment(base: String, wellKnown: [String]) -> String {
        let baseEntries = base
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        var seen = Set(baseEntries)
        var appended: [String] = []
        let fm = FileManager.default
        for entry in wellKnown {
            let expanded = (entry as NSString).expandingTildeInPath
            if seen.contains(expanded) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            appended.append(expanded)
            seen.insert(expanded)
        }
        if base.isEmpty { return appended.joined(separator: ":") }
        if appended.isEmpty { return base }
        return base + ":" + appended.joined(separator: ":")
    }
}
