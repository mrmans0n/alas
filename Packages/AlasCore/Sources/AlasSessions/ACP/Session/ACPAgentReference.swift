import Foundation
import AlasRemoteKit
import AlasACP

/// An agent, and optionally one of its models, that the user named in a
/// prompt by `@`-mentioning it, so the session delegates to it.
///
/// It rides the composer's mention pipeline as an
/// `alas-agent://<agent-id>?model=<model-id>` resource link, like a session
/// mention (see `ACPSessionReference`). Just before sending, the link is
/// replaced on the wire with an inline note naming the `session_new`
/// arguments that start that agent. The recorded user message keeps the link.
public enum ACPAgentReference: Sendable {
    public static let scheme = "alas-agent"

    public struct Target: Equatable, Sendable {
        public let agentId: String
        public let model: String?

        public init(agentId: String, model: String?) {
            self.agentId = agentId
            self.model = model
        }
    }

    public static func uri(for target: Target) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.percentEncodedHost = target.agentId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        if let model = target.model {
            components.queryItems = [URLQueryItem(name: "model", value: model)]
        }
        return components.string ?? "\(scheme)://\(target.agentId)"
    }

    public static func target(fromURI uri: String) -> Target? {
        guard let components = URLComponents(string: uri), components.scheme == scheme,
              let agentId = components.percentEncodedHost?.removingPercentEncoding, !agentId.isEmpty
        else { return nil }
        let model = components.queryItems?.first { $0.name == "model" }?.value
        return Target(agentId: agentId, model: model?.isEmpty == false ? model : nil)
    }

    /// `blocks` with each agent link replaced by `note(for:name:)`. Agents
    /// never see the `alas-agent` scheme: some treat every resource link as
    /// a path to read.
    public static func replacingReferences(in blocks: [ACPContentBlock]) -> [ACPContentBlock] {
        blocks.map { block in
            guard case .resourceLink(let uri, let name) = block, let target = target(fromURI: uri) else {
                return block
            }
            return .text(note(for: target, name: name))
        }
    }

    /// Inline, since the chip usually sits mid-sentence ("ask @Codex to
    /// review this"), and self-describing, so it still reads right after
    /// the session preamble has scrolled out of context.
    public static func note(for target: Target, name: String?) -> String {
        let arguments = "agent \"\(target.agentId)\"" + (target.model.map { ", model \"\($0)\"" } ?? "")
        return "@\(name ?? target.agentId) [an agent the user named: to delegate to it, start a child "
            + "with the alas session_new tool (\(arguments)) rather than your own subagent tool]"
    }
}
