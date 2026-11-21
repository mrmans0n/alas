import Foundation

/// `DiffReviewFileID`: the diff a comment's file belongs to (`staged`, `unstaged`, `commit`, `range`, …) and its path.
public struct RemoteReviewFileID: Codable, Equatable, Hashable, Sendable {
    public let namespace: String
    public let path: String

    public init(namespace: String, path: String) {
        self.namespace = namespace
        self.path = path
    }
}

/// Where a comment sits: `ReviewDraftCommentAnchor` without the parts the phone doesn't show.
public enum RemoteReviewAnchor: Equatable, Sendable {
    case file
    /// `side` is `DiffReviewInlineFeedbackSide`: old, new or unknown.
    case line(side: String, startLine: Int, endLine: Int?)
    case image
}

/// A draft review as a worktree's Reviews list shows it (`HostReviewSummary`).
public struct RemoteReviewSummary: Decodable, Equatable, Identifiable, Sendable {
    /// The draft session id every review request names.
    public let id: String
    /// `ReviewSessionTargetKind`, e.g. local-changes, commit or branch.
    public let kind: String
    public let title: String
    public let source: String
    /// `ReviewSessionStatus`: active, sent, addressing, addressed or reviewed.
    public let status: String
    public let openCommentCount: Int
    public let updatedAt: Date

    /// Whether the host adds comments to it: the kinds `AlasHost+PeerReviews` `comment` accepts.
    public var takesNewComments: Bool {
        ["local-changes", "commit", "tracked-commit", "commit-range", "branch", "review-request"].contains(kind)
    }

    private enum Keys: String, CodingKey {
        case record, openCommentCount, target, status, updatedAt, draftSessionID, kind, title, sourceDescription
    }

    public init(from decoder: Decoder) throws {
        let summary = try decoder.container(keyedBy: Keys.self)
        let record = try summary.nestedContainer(keyedBy: Keys.self, forKey: .record)
        let target = try record.nestedContainer(keyedBy: Keys.self, forKey: .target)
        id = try target.decode(String.self, forKey: .draftSessionID)
        kind = try target.decode(String.self, forKey: .kind)
        title = try target.decode(String.self, forKey: .title)
        source = try target.decodeIfPresent(String.self, forKey: .sourceDescription) ?? ""
        status = try record.decodeIfPresent(String.self, forKey: .status) ?? "active"
        updatedAt = try record.decode(Date.self, forKey: .updatedAt)
        openCommentCount = try summary.decodeIfPresent(Int.self, forKey: .openCommentCount) ?? 0
    }
}

/// One draft comment (`ReviewDraftComment`), its replies included.
public struct RemoteReviewComment: Decodable, Equatable, Identifiable, Sendable {
    public struct Reply: Equatable, Sendable {
        public let author: String
        public let body: String
    }

    public let id: String
    public let fileID: RemoteReviewFileID
    public let path: String
    public let anchor: RemoteReviewAnchor
    public let body: String
    /// `ReviewDraftCommentState`: active, resolved or dismissed.
    public let state: String
    /// As the Mac names them: "You" for the user, else the agent's name.
    public let author: String
    public let replies: [Reply]
    public let updatedAt: Date

    public var isOpen: Bool { state == "active" }

    private enum Keys: String, CodingKey {
        case id, fileID, path, anchor, bodyMarkdown, state, author, replies, updatedAt
        case file, line, image, side, startLine, endLine, user, agent, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        fileID = try c.decode(RemoteReviewFileID.self, forKey: .fileID)
        path = try c.decode(String.self, forKey: .path)
        let anchor = try c.nestedContainer(keyedBy: Keys.self, forKey: .anchor)
        if let line = try? anchor.nestedContainer(keyedBy: Keys.self, forKey: .line) {
            self.anchor = .line(side: try line.decode(String.self, forKey: .side), startLine: try line.decode(Int.self, forKey: .startLine),
                                endLine: try line.decodeIfPresent(Int.self, forKey: .endLine))
        } else {
            self.anchor = anchor.contains(.image) ? .image : .file
        }
        body = try c.decode(String.self, forKey: .bodyMarkdown)
        state = try c.decode(String.self, forKey: .state)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        func name(_ key: Keys, in container: KeyedDecodingContainer<Keys>) -> String {
            guard let author = try? container.nestedContainer(keyedBy: Keys.self, forKey: key),
                  let agent = try? author.nestedContainer(keyedBy: Keys.self, forKey: .agent) else { return "You" }
            let name = (try? agent.decode(String.self, forKey: .name)) ?? ""
            return name.isEmpty ? "Agent" : name
        }
        author = name(.author, in: c)
        var replies: [Reply] = []
        if var list = try? c.nestedUnkeyedContainer(forKey: .replies) {
            while !list.isAtEnd {
                let reply = try list.nestedContainer(keyedBy: Keys.self)
                replies.append(Reply(author: name(.author, in: reply), body: try reply.decode(String.self, forKey: .bodyMarkdown)))
            }
        }
        self.replies = replies
    }
}

/// A draft review with every comment (`HostReview`).
public struct RemoteReview: Equatable, Sendable {
    public let summary: RemoteReviewSummary
    public let comments: [RemoteReviewComment]
}

/// A change to a review's comments, as the phone offers them (`HostReviewMutation`).
public enum RemoteReviewMutation: Equatable, Sendable {
    case add(fileID: RemoteReviewFileID, path: String, anchor: RemoteReviewAnchor, body: String)
    case edit(commentID: String, body: String)
    case delete(commentID: String)
    case resolve(commentID: String)
    case dismiss(commentID: String)
}

/// A pull or merge request thread as its provider shows it to the host's user (`ReviewThread`).
public struct RemoteProviderThread: Decodable, Equatable, Identifiable, Sendable {
    public struct Comment: Decodable, Equatable, Sendable {
        public let author: String?
        public let body: String
    }

    public let id: String
    public let path: String?
    public let line: Int?
    public let isResolved: Bool
    public let isOutdated: Bool
    public let comments: [Comment]
    public let viewerCanResolve: Bool
    public let viewerCanUnresolve: Bool
    public let viewerCanReply: Bool
}

/// A pull or merge request's threads, and what the host's user may do to them (`HostProviderReview`).
public struct RemoteProviderReview: Decodable, Equatable, Sendable {
    public let threads: [RemoteProviderThread]
    /// False when the provider listed only some threads.
    public let areThreadsComplete: Bool
    public let canReply: Bool
    public let canResolve: Bool
    /// The host's login; nil when it can't tell.
    public let account: String?

    private enum Keys: String, CodingKey {
        case request, capabilities, account, threads, areThreadsComplete, canReply, canResolve
    }

    public init(from decoder: Decoder) throws {
        let review = try decoder.container(keyedBy: Keys.self)
        let request = try review.nestedContainer(keyedBy: Keys.self, forKey: .request)
        let capabilities = try review.nestedContainer(keyedBy: Keys.self, forKey: .capabilities)
        threads = try request.decode([RemoteReviewRequest.Lenient<RemoteProviderThread>].self, forKey: .threads).compactMap(\.value)
        areThreadsComplete = try request.decodeIfPresent(Bool.self, forKey: .areThreadsComplete) ?? true
        canReply = try capabilities.decode(Bool.self, forKey: .canReply)
        canResolve = try capabilities.decode(Bool.self, forKey: .canResolve)
        account = try review.decodeIfPresent(String.self, forKey: .account)
    }
}

/// What the phone does to a provider thread (`ProviderThreadMutationKind`).
public enum RemoteProviderThreadAction: String, Sendable {
    case reply, resolve, unresolve
}

/// The draft review verbs as host-protocol messages (`host.reviews.phone.v1`), for a client that
/// carries them as `OpaqueHostMessage`. Mutations are answered as a git action is: see
/// `RemoteGitRequest.reply(to:in:)`.
public enum RemoteReviewRequest {
    public static func list(id: Int, projectID: String, path: String) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["listReviews": ["worktree": ["projectID": projectID, "path": path]]])
    }

    public static func read(id: Int, projectID: String, path: String, sessionID: String) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["readReview": ["worktree": ["projectID": projectID, "path": path], "sessionID": sessionID]])
    }

    public static func mutate(id: Int, projectID: String, path: String, sessionID: String,
                              _ mutation: RemoteReviewMutation) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["mutateReview": [
            "worktree": ["projectID": projectID, "path": path], "sessionID": sessionID, "mutation": encode(mutation),
        ]])
    }

    /// `ReviewDraftSessionID.localChanges(worktreeID:worktreePath:scope: .all)`, so the phone can
    /// comment on a worktree's local changes before the Mac lists a review of them.
    public static func localChangesSessionID(worktreeID: String, worktreePath: String) -> String {
        let fields = ["local-changes", worktreeID, URL(fileURLWithPath: worktreePath).standardizedFileURL.path, "all"]
        return fields.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\u{1f}", with: "\\u001f")
        }.joined(separator: "\u{1f}")
    }

    /// A pull or merge request review's threads (`host.reviews.provider.phone.v1`), without its diff.
    public static func readProvider(id: Int, projectID: String, path: String, sessionID: String) -> OpaqueHostMessage {
        RemoteGitRequest.envelope(id: id, ["readProviderReview": [
            "worktree": ["projectID": projectID, "path": path], "sessionID": sessionID, "withDiff": false,
        ]])
    }

    /// Replies to, resolves or unresolves a provider thread, as the host's user; answered as a git action is.
    public static func mutateThread(id: Int, projectID: String, path: String, sessionID: String, threadID: String,
                                    _ action: RemoteProviderThreadAction, body: String? = nil) -> OpaqueHostMessage {
        var request: [String: Any] = [
            "worktree": ["projectID": projectID, "path": path], "sessionID": sessionID, "threadID": threadID, "kind": action.rawValue,
        ]
        request["body"] = body
        return RemoteGitRequest.envelope(id: id, ["mutateReviewThread": request])
    }

    public static func providerReview(replying id: Int? = nil, in message: OpaqueHostMessage) -> RemoteProviderReview? {
        decode(RemoteProviderReview.self, at: "providerReview", "review", replying: id, in: message)
    }

    /// A provider failure as the phone words it: a CLI missing or signed out on the Mac reads as
    /// what to do there, not as its raw error.
    public static func providerFailureMessage(_ message: String) -> String {
        let lower = message.lowercased()
        let cli = lower.hasPrefix("glab") || lower.contains("glab auth") ? "glab" : "gh"
        if lower.contains("is not installed") {
            return "\(cli) isn't installed on the Mac. Install it there, then pull to refresh."
        }
        let signedOut = ["auth login", "not logged in", "authentication is required", "bad credentials", "http 401", "401 unauthorized"]
        if signedOut.contains(where: lower.contains) {
            return "Sign in to \(cli) on the Mac (run \(cli) auth login there), then pull to refresh."
        }
        return message
    }

    public static func reviews(replying id: Int? = nil, in message: OpaqueHostMessage) -> [RemoteReviewSummary]? {
        decode([Lenient<RemoteReviewSummary>].self, at: "reviews", "reviews", replying: id, in: message)?.compactMap(\.value)
    }

    public static func review(replying id: Int? = nil, in message: OpaqueHostMessage) -> RemoteReview? {
        guard let review = decode(LenientReview.self, at: "review", "review", replying: id, in: message) else { return nil }
        return RemoteReview(summary: review.summary, comments: review.comments.compactMap(\.value))
    }

    private static func decode<T: Decodable>(_ type: T.Type, at result: String, _ field: String,
                                             replying id: Int?, in message: OpaqueHostMessage) -> T? {
        guard let object = try? JSONSerialization.jsonObject(with: message.json) as? [String: Any],
              let response = object["response"] as? [String: Any], id == nil || response["id"] as? Int == id,
              let raw = ((response["result"] as? [String: Any])?[result] as? [String: Any])?[field],
              let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode(_ mutation: RemoteReviewMutation) -> [String: Any] {
        switch mutation {
        case .add(let fileID, let path, let anchor, let body):
            let anchor: [String: Any] = switch anchor {
            case .file, .image: ["file": [String: Any]()]
            case .line(let side, let startLine, let endLine):
                ["line": ["side": side, "startLine": startLine, "endLine": endLine ?? startLine]]
            }
            return ["add": ["fileID": ["namespace": fileID.namespace, "path": fileID.path], "path": path,
                            "anchor": anchor, "body": body]]
        case .edit(let commentID, let body): return ["edit": ["commentID": commentID, "body": body]]
        case .delete(let commentID): return ["delete": ["commentID": commentID]]
        case .resolve(let commentID): return ["resolve": ["commentID": commentID]]
        case .dismiss(let commentID): return ["dismiss": ["commentID": commentID]]
        }
    }

    /// Skips an entry a newer host sends in a shape the phone can't read.
    fileprivate struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private struct LenientReview: Decodable {
        let summary: RemoteReviewSummary
        let comments: [Lenient<RemoteReviewComment>]
    }
}
