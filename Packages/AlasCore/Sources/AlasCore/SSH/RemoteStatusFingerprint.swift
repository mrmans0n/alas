import Foundation

public enum RemoteStatusFingerprint: Sendable {
    public static func make(
        status: String,
        head: String,
        unstagedDiff: String = "",
        stagedDiff: String = "",
        untrackedContent: String = ""
    ) -> String {
        [status, head, unstagedDiff, stagedDiff, untrackedContent].joined(separator: "\u{0}")
    }

    public static func shouldRefresh(previous: String?, current: String) -> Bool {
        previous.map { $0 != current } ?? true
    }
}
