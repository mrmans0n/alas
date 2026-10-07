import Foundation

enum AlasCLIRequestError: Error, Equatable {
    case malformed
    case unsupportedKind
    case unsupportedVersion
    case unsupportedCommand
    case missingSession
    case missingPaths
}

enum ReviewCommentWireFilter: String, Equatable {
    case active
    case resolved
    case dismissed
    case all
}

enum ReviewVerdictWire: String, Equatable {
    case approve
    case requestChanges = "request_changes"
    case comment

    var reviewVerdict: ReviewVerdict {
        switch self {
        case .approve: .approve
        case .requestChanges: .requestChanges
        case .comment: .comment
        }
    }
}

enum AlasCLINotifyLevel: String, Equatable {
    case info
    case attention
}

struct AlasCLIRequest: Equatable {
    enum Command: Equatable {
        case open(paths: [String])
        case openAt(path: String, line: Int, endLine: Int?)
        case notify(body: String, title: String?, level: AlasCLINotifyLevel)
        case worktree(WorktreeCommand)
        case workspace(WorkspaceCommand)
        case preview(WebPreviewCommand)
        case review(ReviewCommand)
        case agentList(worktree: String?)
        case sessionList
        case sessionNew(
            prompt: String,
            agentID: String?,
            worktree: SessionWorktreeSelector,
            model: String? = nil,
            reasoning: String? = nil,
            role: String? = nil
        )
        case sessionSend(sessionID: String, prompt: String)
        /// MCP-only: show a visual aid in the calling ACP session.
        case visualShow(title: String, html: String, question: ACPVisualAid.Question?)
        /// `session_read`, `session_search`, `session_wait`, `session_interrupt`.
        case sessionAction(ACPDelegatedSessionAction)
        case resolve
    }

    /// A CLI run inside a remote terminal reports paths on the remote host;
    /// re-key absolute `open` paths and worktree targets onto the caller's virtual namespace. Local anchors
    /// leave the request unchanged.
    func virtualizingPaths(like anchor: String) -> AlasCLIRequest {
        let mapped: Command
        switch command {
        case .open(let paths):
            mapped = .open(paths: paths.map { RemotePath.virtualizing($0, like: anchor) })
        case .openAt(let path, let line, let endLine):
            mapped = .openAt(path: RemotePath.virtualizing(path, like: anchor), line: line, endLine: endLine)
        case .worktree(.switch(let target)):
            mapped = .worktree(.switch(target: RemotePath.virtualizing(target, like: anchor)))
        case .worktree(.delete(let target, let force, let keepBranch)):
            mapped = .worktree(.delete(target: RemotePath.virtualizing(target, like: anchor), force: force, keepBranch: keepBranch))
        case .review(.localChanges(let worktree)):
            mapped = .review(.localChanges(worktree: worktree.map { RemotePath.virtualizing($0, like: anchor) }))
        case .review(.target(let target, let worktree)):
            mapped = .review(.target(target, worktree: worktree.map { RemotePath.virtualizing($0, like: anchor) }))
        case .review(.commentAdd(let path, let startLine, let endLine, let side, let body, let sessionID)):
            mapped = .review(.commentAdd(
                path: RemotePath.virtualizing(path, like: anchor), startLine: startLine, endLine: endLine,
                side: side, body: body, sessionID: sessionID
            ))
        case .agentList(let worktree):
            mapped = .agentList(worktree: worktree.map { RemotePath.virtualizing($0, like: anchor) })
        case .sessionNew(let prompt, let agentID, .existing(let id), let model, let reasoning, let role):
            mapped = .sessionNew(
                prompt: prompt, agentID: agentID,
                worktree: .existing(worktreeID: RemotePath.virtualizing(id, like: anchor)),
                model: model, reasoning: reasoning, role: role
            )
        default:
            return self
        }
        return AlasCLIRequest(version: version, sessionId: sessionId, cwd: cwd, command: mapped)
    }

    enum WorktreeCommand: Equatable {
        case list
        case `switch`(target: String)
        case new(branch: String, base: String?)
        case delete(target: String, force: Bool, keepBranch: Bool)
    }

    enum WorkspaceCommand: Equatable {
        case list
        case show(checkoutID: UUID)
        case `switch`(checkoutID: UUID)
        case focus(checkoutID: UUID, memberID: UUID)
    }

    enum ReviewCommand: Equatable {
        case localChanges(worktree: String?)
        case target(String, worktree: String?)
        case comments(sessionID: String?, state: ReviewCommentWireFilter)
        case reply(commentID: String, body: String)
        case resolve(commentID: String, reply: String?, reopen: Bool)
        case commentAdd(path: String, startLine: Int, endLine: Int?, side: String?, body: String, sessionID: String?)
        case finish(sessionID: String?, verdict: ReviewVerdict, summary: String)
    }

    enum SessionWorktreeSelector: Equatable {
        case current
        case existing(worktreeID: String)
        case new(branch: String, base: String?)
    }

    let version: Int
    let sessionId: String?
    let cwd: String?
    let command: Command

    var paths: [String] {
        switch command {
        case .open(let paths):
            return paths
        case .openAt(let path, _, _):
            return [path]
        default:
            return []
        }
    }

    private struct Raw: Decodable {
        var v: Int?
        var kind: String?
        var command: String?
        var subcommand: String?
        var session_id: String?
        var cwd: String?
        var paths: [String]?
        var target: String?
        var branch: String?
        var base: String?
        var force: Bool?
        var keep_branch: Bool?
        var checkout_id: String?
        var member_id: String?
    }

    private struct ParamsEnvelope<P: Decodable>: Decodable {
        var params: P?
    }

    private struct OpenParams: Decodable {
        var line: Int?
        var end_line: Int?
    }

    private struct ReviewParams: Decodable {
        var worktree: String?
    }

    private struct ReviewCommentsParams: Decodable {
        var session_id: String?
        var state: String?
    }

    private struct ReviewReplyParams: Decodable {
        var comment_id: String
        var body: String
    }

    private struct ReviewResolveParams: Decodable {
        var comment_id: String
        var reply: String?
        var reopen: Bool?
    }

    private struct ReviewCommentAddParams: Decodable {
        var path: String
        var start_line: Int
        var end_line: Int?
        var side: String?
        var body: String
        var session_id: String?
    }

    private struct ReviewFinishParams: Decodable {
        var session_id: String?
        var verdict: String?
        var summary: String?
    }

    private struct NotifyParams: Decodable {
        var body: String
        var title: String?
        var level: String?
    }

    private struct AgentListParams: Decodable {
        var worktree: String?
    }

    private struct SessionListParams: Decodable {}

    private struct SessionNewParams: Decodable {
        struct NewWorktree: Decodable {
            var branch: String
            var base: String?
        }

        var prompt: String
        var agent: String?
        var model: String?
        var reasoning: String?
        var role: String?
        var worktree: String?
        var new_worktree: NewWorktree?
    }

    private struct SessionSendParams: Decodable {
        var session_id: String
        var prompt: String
    }

    private struct VisualShowParams: Decodable {
        struct Option: Decodable {
            var id: String
            var label: String
        }

        struct Question: Decodable {
            var prompt: String
            var options: [Option]
            var allow_multiple: Bool?
        }

        var title: String
        var html: String
        var question: Question?
    }

    private struct SessionReadParams: Decodable {
        var session_id: String
        var offset: Int?
        var limit: Int?
        var max_chars: Int?
    }

    private struct SessionSearchParams: Decodable {
        var query: String
        var limit: Int?
    }

    private struct SessionWaitParams: Decodable {
        var session_ids: [String]
        var timeout_ms: Int?
    }

    private struct SessionInterruptParams: Decodable {
        var session_id: String
    }

    private struct WorkspaceParams: Decodable {
        var checkout_id: String?
        var member_id: String?
    }

    /// Typed access to the `params` object new-style commands carry.
    /// Returns nil when `params` is absent or explicitly null (`Decodable`
    /// synthesis treats both the same way); throws `.malformed` when
    /// `params` is present with a non-null value that does not match `P`.
    static func decodeParamsIfPresent<P: Decodable>(_ type: P.Type, from data: Data) throws -> P? {
        do {
            return try JSONDecoder().decode(ParamsEnvelope<P>.self, from: data).params
        } catch {
            throw AlasCLIRequestError.malformed
        }
    }

    /// Like `decodeParamsIfPresent`, but the command requires arguments.
    static func decodeParams<P: Decodable>(_ type: P.Type, from data: Data) throws -> P {
        guard let params = try decodeParamsIfPresent(type, from: data) else {
            throw AlasCLIRequestError.malformed
        }
        return params
    }

    static func decode(from data: Data) throws -> AlasCLIRequest {
        func requiredNonEmpty(_ value: String?) throws -> String {
            guard let value else { throw AlasCLIRequestError.malformed }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AlasCLIRequestError.malformed }
            return trimmed
        }

        func validatedAbsolutePaths(_ paths: [String]?) throws -> [String] {
            guard let paths,
                  !paths.isEmpty,
                  paths.allSatisfy({
                      let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                      return !trimmed.isEmpty && URL(fileURLWithPath: trimmed).path == trimmed && trimmed.hasPrefix("/")
                  }) else {
                throw AlasCLIRequestError.missingPaths
            }
            return paths
        }

        /// `value` when inside `range`, `fallback` when absent.
        func bounded(_ value: Int?, _ range: ClosedRange<Int>, default fallback: Int) throws -> Int {
            guard let value else { return fallback }
            guard range.contains(value) else { throw AlasCLIRequestError.malformed }
            return value
        }

        func requiredUUID(_ value: String?) throws -> UUID {
            guard let raw = value?.nilIfBlank, let id = UUID(uuidString: raw) else {
                throw AlasCLIRequestError.malformed
            }
            return id
        }

        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw AlasCLIRequestError.malformed
        }
        guard raw.kind == "cli" else { throw AlasCLIRequestError.unsupportedKind }
        guard raw.v == 1 else { throw AlasCLIRequestError.unsupportedVersion }
        let sessionId = raw.session_id?.nilIfBlank
        // Validate against the raw value and return it unchanged: trimming
        // would silently resolve a different directory than the one the CLI
        // sent for a path that legitimately ends in whitespace (the Rust
        // side already sends absolutized, non-trimmed paths). Whitespace is
        // checked only to reject an effectively-empty value.
        let cwd = try raw.cwd.map { rawCwd -> String in
            guard !rawCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  rawCwd.hasPrefix("/"),
                  URL(fileURLWithPath: rawCwd).path == rawCwd else {
                throw AlasCLIRequestError.malformed
            }
            return rawCwd
        }
        guard sessionId != nil || cwd != nil else {
            throw AlasCLIRequestError.missingSession
        }

        let command: Command
        switch raw.command {
        case "open":
            let paths = try validatedAbsolutePaths(raw.paths)
            let params = try Self.decodeParamsIfPresent(OpenParams.self, from: data)
            if let line = params?.line {
                guard paths.count == 1,
                      line >= 1,
                      params?.end_line.map({ $0 >= line }) ?? true else {
                    throw AlasCLIRequestError.malformed
                }
                command = .openAt(path: paths[0], line: line, endLine: params?.end_line)
            } else {
                guard params?.end_line == nil else { throw AlasCLIRequestError.malformed }
                command = .open(paths: paths)
            }
        case "notify":
            let params = try Self.decodeParams(NotifyParams.self, from: data)
            let level: AlasCLINotifyLevel
            if let rawLevel = params.level?.nilIfBlank {
                guard let parsed = AlasCLINotifyLevel(rawValue: rawLevel) else {
                    throw AlasCLIRequestError.malformed
                }
                level = parsed
            } else {
                level = .attention
            }
            command = .notify(
                body: try requiredNonEmpty(params.body),
                title: params.title?.nilIfBlank,
                level: level
            )
        case "wt":
            switch raw.subcommand {
            case "list":
                command = .worktree(.list)
            case "switch":
                command = .worktree(.switch(target: try requiredNonEmpty(raw.target)))
            case "new":
                command = .worktree(.new(branch: try requiredNonEmpty(raw.branch), base: raw.base?.nilIfBlank))
            case "delete":
                command = .worktree(.delete(
                    target: try requiredNonEmpty(raw.target),
                    force: raw.force ?? false,
                    keepBranch: raw.keep_branch ?? false
                ))
            default:
                throw AlasCLIRequestError.unsupportedCommand
            }
        case "workspace":
            let params = try Self.decodeParamsIfPresent(WorkspaceParams.self, from: data)
            switch raw.subcommand {
            case "list":
                command = .workspace(.list)
            case "show":
                command = .workspace(.show(checkoutID: try requiredUUID(params?.checkout_id ?? raw.checkout_id)))
            case "switch":
                command = .workspace(.switch(checkoutID: try requiredUUID(params?.checkout_id ?? raw.checkout_id)))
            case "focus":
                command = .workspace(.focus(
                    checkoutID: try requiredUUID(params?.checkout_id ?? raw.checkout_id),
                    memberID: try requiredUUID(params?.member_id ?? raw.member_id)
                ))
            default:
                throw AlasCLIRequestError.unsupportedCommand
            }
        case "review":
            let params = try Self.decodeParamsIfPresent(ReviewParams.self, from: data)
            let worktree = params?.worktree?.nilIfBlank
            if let target = raw.target?.nilIfBlank {
                command = .review(.target(target, worktree: worktree))
            } else {
                command = .review(.localChanges(worktree: worktree))
            }
        case "review_comments":
            let params = try Self.decodeParamsIfPresent(ReviewCommentsParams.self, from: data)
            let filter: ReviewCommentWireFilter
            if let rawState = params?.state?.nilIfBlank {
                guard let parsed = ReviewCommentWireFilter(rawValue: rawState) else {
                    throw AlasCLIRequestError.malformed
                }
                filter = parsed
            } else {
                filter = .active
            }
            command = .review(.comments(sessionID: params?.session_id?.nilIfBlank, state: filter))
        case "review_reply":
            let params = try Self.decodeParams(ReviewReplyParams.self, from: data)
            command = .review(.reply(
                commentID: try requiredNonEmpty(params.comment_id),
                body: try requiredNonEmpty(params.body)
            ))
        case "review_resolve":
            let params = try Self.decodeParams(ReviewResolveParams.self, from: data)
            command = .review(.resolve(
                commentID: try requiredNonEmpty(params.comment_id),
                reply: params.reply?.nilIfBlank,
                reopen: params.reopen ?? false
            ))
        case "review_comment_add":
            let params = try Self.decodeParams(ReviewCommentAddParams.self, from: data)
            guard params.start_line >= 1,
                  params.end_line.map({ $0 >= params.start_line }) ?? true else {
                throw AlasCLIRequestError.malformed
            }
            let side = try params.side.map { raw -> String in
                guard raw == "old" || raw == "new" else { throw AlasCLIRequestError.malformed }
                return raw
            }
            command = .review(.commentAdd(
                path: try requiredNonEmpty(params.path),
                startLine: params.start_line,
                endLine: params.end_line,
                side: side,
                body: try requiredNonEmpty(params.body),
                sessionID: params.session_id?.nilIfBlank
            ))
        case "review_finish":
            let params = try Self.decodeParamsIfPresent(ReviewFinishParams.self, from: data)
            let verdict: ReviewVerdict
            if let rawVerdict = params?.verdict?.nilIfBlank {
                guard let parsed = ReviewVerdictWire(rawValue: rawVerdict) else {
                    throw AlasCLIRequestError.malformed
                }
                verdict = parsed.reviewVerdict
            } else {
                verdict = .comment
            }
            command = .review(.finish(
                sessionID: params?.session_id?.nilIfBlank,
                verdict: verdict,
                summary: params?.summary ?? ""
            ))
        case "agent_list":
            let params = try Self.decodeParams(AgentListParams.self, from: data)
            command = .agentList(worktree: try params.worktree.map(requiredNonEmpty))
        case "session_list":
            _ = try Self.decodeParams(SessionListParams.self, from: data)
            command = .sessionList
        case "session_new":
            let params = try Self.decodeParams(SessionNewParams.self, from: data)
            let worktree: SessionWorktreeSelector
            let existingWorktree = try params.worktree.map(requiredNonEmpty)
            if let newWorktree = params.new_worktree {
                guard existingWorktree == nil else {
                    throw AlasCLIRequestError.malformed
                }
                worktree = .new(
                    branch: try requiredNonEmpty(newWorktree.branch),
                    base: newWorktree.base?.nilIfBlank
                )
            } else if let existingWorktree {
                worktree = .existing(worktreeID: existingWorktree)
            } else {
                worktree = .current
            }
            command = .sessionNew(
                prompt: try requiredNonEmpty(params.prompt),
                agentID: try params.agent.map(requiredNonEmpty),
                worktree: worktree,
                model: try params.model.map(requiredNonEmpty),
                reasoning: try params.reasoning.map(requiredNonEmpty),
                role: try params.role.map(requiredNonEmpty)
            )
        case "session_send":
            let params = try Self.decodeParams(SessionSendParams.self, from: data)
            command = .sessionSend(
                sessionID: try requiredNonEmpty(params.session_id),
                prompt: try requiredNonEmpty(params.prompt)
            )
        case "visual_show":
            let params = try Self.decodeParams(VisualShowParams.self, from: data)
            let title = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let question = params.question.map { question in
                ACPVisualAid.Question(
                    prompt: question.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    options: question.options.map {
                        .init(id: $0.id, label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines))
                    },
                    allowMultiple: question.allow_multiple ?? false
                )
            }
            guard ACPVisualAid.validationFailure(title: title, html: params.html, question: question) == nil else {
                throw AlasCLIRequestError.malformed
            }
            command = .visualShow(title: title, html: params.html, question: question)
        case "session_read":
            let params = try Self.decodeParams(SessionReadParams.self, from: data)
            if let offset = params.offset, offset < 0 { throw AlasCLIRequestError.malformed }
            command = .sessionAction(.read(ACPDelegatedSessionReadRequest(
                targetSessionId: try requiredNonEmpty(params.session_id),
                offset: params.offset,
                limit: try bounded(
                    params.limit, 1...ACPDelegatedSessionReadRequest.maxLimit,
                    default: ACPDelegatedSessionReadRequest.defaultLimit
                ),
                maxChars: try bounded(
                    params.max_chars, 1...ACPDelegatedSessionReadRequest.maxMaxChars,
                    default: ACPDelegatedSessionReadRequest.defaultMaxChars
                )
            )))
        case "session_search":
            let params = try Self.decodeParams(SessionSearchParams.self, from: data)
            command = .sessionAction(.search(ACPDelegatedSessionSearchRequest(
                query: try requiredNonEmpty(params.query),
                limit: try bounded(
                    params.limit, 1...ACPDelegatedSessionSearchRequest.maxLimit,
                    default: ACPDelegatedSessionSearchRequest.defaultLimit
                )
            )))
        case "session_wait":
            let params = try Self.decodeParams(SessionWaitParams.self, from: data)
            guard (1...ACPDelegatedSessionWaitRequest.maxSessions).contains(params.session_ids.count) else {
                throw AlasCLIRequestError.malformed
            }
            command = .sessionAction(.wait(ACPDelegatedSessionWaitRequest(
                targetSessionIds: try params.session_ids.map(requiredNonEmpty),
                timeoutMillis: try bounded(
                    params.timeout_ms, 1...ACPDelegatedSessionWaitRequest.maxTimeoutMillis,
                    default: ACPDelegatedSessionWaitRequest.maxTimeoutMillis
                )
            )))
        case "session_interrupt":
            let params = try Self.decodeParams(SessionInterruptParams.self, from: data)
            command = .sessionAction(.interrupt(targetSessionId: try requiredNonEmpty(params.session_id)))
        case let name? where name.hasPrefix("preview_"):
            guard let action = WebPreviewCommand.Action(rawValue: String(name.dropFirst("preview_".count))) else {
                throw AlasCLIRequestError.unsupportedCommand
            }
            command = .preview(try WebPreviewCommand.decode(action: action, data: data))
        case "resolve":
            command = .resolve
        default:
            throw AlasCLIRequestError.unsupportedCommand
        }

        return AlasCLIRequest(version: 1, sessionId: sessionId, cwd: cwd, command: command)
    }
}

enum AlasCLIResponse: Equatable {
    case ok
    case text([String])
    case error(String)
    case errorWithExitCode(String, Int)

    func encode() throws -> Data {
        var object: [String: Any]
        switch self {
        case .ok:
            object = ["ok": true]
        case .text(let lines):
            object = ["ok": true, "lines": lines]
        case .error(let message):
            object = ["ok": false, "error": message]
        case .errorWithExitCode(let message, let exitCode):
            object = ["ok": false, "error": message]
            if exitCode != 1 {
                object["exit_code"] = exitCode
            }
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
