import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

extension CodeHostReference {
    /// Browser URL before any lookup has resolved the kind. GitHub redirects
    /// `/issues/N` to `/pull/N` when N is a pull request.
    public func webURL(on remote: CodeHostRemote) -> URL {
        switch (remote.kind, sigil) {
        case (.gitlab, .bang):
            return remote.reviewRequestURL(number: number)
        case (.gitlab, .hash):
            return remote.webURL.appendingPathComponent("-")
                .appendingPathComponent("issues").appendingPathComponent("\(number)")
        case (.github, _):
            return remote.webURL.appendingPathComponent("issues").appendingPathComponent("\(number)")
        }
    }
}

extension CodeHostKind {
    public var cliExecutable: String {
        switch self {
        case .github: "gh"
        case .gitlab: "glab"
        }
    }
}

extension CodeHostRemote {
    /// What a remote viewer needs to know about this repository.
    public var codeHost: RemoteCodeHost { RemoteCodeHost(kind: kind, host: host, webURL: webURL) }
}
