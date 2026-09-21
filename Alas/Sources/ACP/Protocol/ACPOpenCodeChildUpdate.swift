import Foundation

/// OpenCode v2's variant of native subagent sessions.
///
/// Instead of child-scoped `session/update` notifications, OpenCode sends
/// `opencode/session/child_update` on the root session, wrapping either an
/// ordinary `SessionUpdate` or a lifecycle status. Alas normalizes both into
/// the standard shapes at the client boundary so exactly one routing path
/// exists downstream (see `ACPSessionRunner.applyIncomingUpdate`).
struct ACPOpenCodeChildUpdate: Decodable, Equatable {
    static let method = "opencode/session/child_update"

    let rootSessionId: String
    let childSessionId: String
    let parentSessionId: String?
    let depth: Int?
    let title: String?
    let payload: Payload

    enum Payload: Equatable {
        case update(ACPSessionUpdate)
        case status(ACPSubagentState, error: String?)
    }

    private enum CodingKeys: String, CodingKey {
        case rootSessionId, childSessionId, parentSessionId, depth, title, type, update, status, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootSessionId = try c.decode(String.self, forKey: .rootSessionId)
        childSessionId = try c.decode(String.self, forKey: .childSessionId)
        parentSessionId = try? c.decodeIfPresent(String.self, forKey: .parentSessionId)
        depth = try? c.decodeIfPresent(Int.self, forKey: .depth)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        let type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        switch type {
        case "status":
            let raw = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
            payload = .status(
                ACPSubagentState(rawValue: raw ?? "running"),
                error: (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
            )
        default:
            // `type` defaults to "update" — OpenCode omits it on some builds.
            payload = .update(try c.decode(ACPSessionUpdate.self, forKey: .update))
        }
    }

    /// The equivalent standard notifications, in the order they must be
    /// applied.
    ///
    /// Every child notification is prefixed with a `subagent_spawned`
    /// because OpenCode has no explicit spawn message and may send a child's
    /// first output before (or entirely without) a `status: "created"`.
    /// Registration is idempotent, so replaying it costs nothing and
    /// guarantees the child is routable by the time its output lands.
    var normalized: [ACPSessionUpdateParams] {
        let spawn = ACPSessionUpdateParams(
            sessionId: rootSessionId,
            update: .subagentSpawned(.init(
                subagentSessionId: childSessionId,
                name: title,
                task: nil
            ))
        )
        switch payload {
        case .update(let update):
            return [spawn, .init(sessionId: childSessionId, update: update)]
        case .status(let state, let error):
            return [
                spawn,
                .init(
                    sessionId: rootSessionId,
                    update: .subagentStateUpdate(.init(
                        subagentSessionId: childSessionId,
                        state: state,
                        error: error
                    ))
                )
            ]
        }
    }

    /// Decodes a raw `opencode/session/child_update` params object into the
    /// standard notifications it stands for. Returns an empty array when the
    /// payload is not a child update Alas understands.
    static func normalize(params: Data, decoder: JSONDecoder = JSONDecoder()) -> [ACPSessionUpdateParams] {
        guard let decoded = try? decoder.decode(ACPOpenCodeChildUpdate.self, from: params) else {
            return []
        }
        return decoded.normalized
    }
}
