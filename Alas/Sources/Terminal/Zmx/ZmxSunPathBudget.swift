import Foundation

/// macOS Unix-domain sockets are bound through `sockaddr_un.sun_path`, which
/// holds 104 bytes **including the trailing NUL** — so the usable path is at
/// most 103 bytes. zmx creates sockets named "<sessionName>.sock" under
/// `ZMX_DIR`; a full bind path is `<dir>/<sessionName>.sock`. The longest
/// session name we ever produce is
/// `ZmxSessionName.derive(worktreeId: ..., leafId: ...)` → 38 chars; basename
/// adds ".sock" for 43 chars, plus the path separator = 44 chars of overhead.
enum ZmxSunPathBudget {
    /// Total bytes in `sockaddr_un.sun_path` on macOS, including the NUL
    /// terminator. The usable path length is `sunPathTotal - 1`.
    static let sunPathTotal = 104
    static let longestSocketBasenameOverhead = 44   // "/<38-char-name>.sock"

    /// True when `<dir>/<longest-basename>` still fits within sun_path —
    /// reserving one byte for the NUL terminator that `bind(2)` requires.
    static func fits(dir: String) -> Bool {
        dir.utf8.count + longestSocketBasenameOverhead <= sunPathTotal - 1
    }
}
