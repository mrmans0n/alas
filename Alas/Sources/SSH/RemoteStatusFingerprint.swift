import Foundation

enum RemoteStatusFingerprint {
    static func make(status: String, head: String) -> String { status + "\u{0}" + head }
    static func shouldRefresh(previous: String?, current: String) -> Bool {
        previous.map { $0 != current } ?? false
    }
}
